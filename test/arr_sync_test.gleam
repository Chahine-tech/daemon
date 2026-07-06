import arr_sync/client/qbittorrent
import arr_sync/config
import arr_sync/matcher/piece_hasher
import arr_sync/matcher/torrent_index
import arr_sync/watcher/fs_watcher
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn torrent_summary_decoder_parses_a_real_torrents_info_response_test() {
  // Captured live from a real qBittorrent 5.2.2 /api/v2/torrents/info entry.
  let body =
    "{\"hash\":\"dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c\",\"name\":\"Big Buck Bunny\",\"save_path\":\"/downloads\"}"

  let assert Ok(summary) =
    json.parse(body, qbittorrent.torrent_summary_decoder())
  assert summary.hash == "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"
  assert summary.name == "Big Buck Bunny"
  assert summary.save_path == "/downloads"
}

pub fn remote_torrent_file_decoder_accepts_integer_progress_test() {
  // Regression: qBittorrent serialises whole-number progress as a bare
  // JSON int (`1`, not `1.0`) once a file is complete — this exact shape
  // came from a live 5.2.2 response and broke decode.float alone.
  let body =
    "{\"name\":\"ShowPack/episode.bin\",\"size\":80000,\"progress\":1,\"piece_range\":[0,2]}"

  let assert Ok(file) =
    json.parse(body, qbittorrent.remote_torrent_file_decoder())
  assert file.progress == 1.0
  assert file.piece_range == #(0, 2)
}

pub fn remote_torrent_file_decoder_accepts_float_progress_test() {
  let body =
    "{\"name\":\"ShowPack/episode.bin\",\"size\":80000,\"progress\":0.5,\"piece_range\":[1,3]}"

  let assert Ok(file) =
    json.parse(body, qbittorrent.remote_torrent_file_decoder())
  assert file.progress == 0.5
}

pub fn properties_decoder_parses_a_real_properties_response_test() {
  // Captured live: piece_size lives here, not in torrents/info.
  let body =
    "{\"piece_size\":32768,\"pieces_num\":2,\"infohash_v1\":\"172274958c72543657e80417f44785921483c743\"}"

  let assert Ok(properties) = json.parse(body, qbittorrent.properties_decoder())
  assert properties.piece_size == 32_768
  assert properties.infohash_v1 == "172274958c72543657e80417f44785921483c743"
}

pub fn properties_decoder_parses_an_empty_infohash_v1_test() {
  // Captured live from a pure BitTorrent v2 torrent (qBittorrent 5.2.2):
  // infohash_v1 is "" — the signal torrent_index uses to skip a torrent
  // whose pieceHashes qBittorrent can't actually report correctly.
  let body = "{\"piece_size\":65536,\"pieces_num\":32,\"infohash_v1\":\"\"}"

  let assert Ok(properties) = json.parse(body, qbittorrent.properties_decoder())
  assert properties.infohash_v1 == ""
}

fn sample_entry(
  hash: String,
  piece_hashes: List(String),
) -> torrent_index.TorrentEntry {
  torrent_index.TorrentEntry(
    hash:,
    name: hash,
    save_path: "/data/" <> hash,
    files: [],
    piece_size: 4_194_304,
    piece_hashes:,
  )
}

pub fn find_match_returns_matched_for_a_unique_piece_hash_test() {
  let index =
    torrent_index.build_index([
      sample_entry("torrent-a", ["hash-1", "hash-2"]),
      sample_entry("torrent-b", ["hash-3"]),
    ])

  assert torrent_index.find_match(index, "hash-2")
    == torrent_index.Matched("torrent-a", "hash-2")
}

pub fn resolve_finds_the_file_containing_the_matched_piece_test() {
  let entry =
    torrent_index.TorrentEntry(
      hash: "torrent-a",
      name: "torrent-a",
      save_path: "/data/torrent-a",
      files: [
        torrent_index.TorrentFile(
          name: "a.srt",
          size: 10,
          progress: 1.0,
          piece_range: #(0, 0),
        ),
        torrent_index.TorrentFile(
          name: "a.mkv",
          size: 1000,
          progress: 1.0,
          piece_range: #(1, 5),
        ),
      ],
      piece_size: 4_194_304,
      piece_hashes: ["h0", "h1", "h2", "h3", "h4", "h5"],
    )
  let index = torrent_index.build_index([entry])

  let assert Ok(#(resolved_entry, file)) =
    torrent_index.resolve(index, "torrent-a", "h3")
  assert resolved_entry.hash == "torrent-a"
  assert file.name == "a.mkv"
}

pub fn find_match_returns_no_match_for_an_unknown_piece_hash_test() {
  let index = torrent_index.build_index([sample_entry("torrent-a", ["hash-1"])])

  assert torrent_index.find_match(index, "unknown") == torrent_index.NoMatch
}

pub fn build_index_does_not_treat_a_repeated_piece_hash_within_one_torrent_as_ambiguous_test() {
  // Regression: a torrent whose content repeats (e.g. a long run of
  // identical bytes) can hash the same piece_hash more than once. That
  // used to get counted as two "candidates" for the same torrent_hash and
  // misreported as cross-torrent ambiguity.
  let index =
    torrent_index.build_index([sample_entry("torrent-a", ["dup", "dup"])])

  assert torrent_index.find_match(index, "dup")
    == torrent_index.Matched("torrent-a", "dup")
}

pub fn find_match_returns_ambiguous_when_two_torrents_share_a_piece_hash_test() {
  let index =
    torrent_index.build_index([
      sample_entry("torrent-a", ["shared-hash"]),
      sample_entry("torrent-b", ["shared-hash"]),
    ])

  let assert torrent_index.Ambiguous(piece_hash, candidates) =
    torrent_index.find_match(index, "shared-hash")

  assert piece_hash == "shared-hash"
  assert list_contains_both(candidates, "torrent-a", "torrent-b")
}

fn list_contains_both(candidates: List(String), a: String, b: String) -> Bool {
  case candidates {
    [x, y] -> { x == a && y == b } || { x == b && y == a }
    _ -> False
  }
}

// Mirrors a layout verified live (qBittorrent 5.2.2, v1 torrent, no pad
// files): aaa.dat is 100000 bytes so episode.bin starts at offset 100000 —
// not a multiple of the 32768 piece size. Piece 3 straddles both files;
// episode.bin's first fully contained piece is piece 4, which starts
// 31072 bytes into the file.
fn misaligned_pack_entry() -> torrent_index.TorrentEntry {
  torrent_index.TorrentEntry(
    hash: "pack-d",
    name: "PackD",
    save_path: "/data/PackD",
    files: [
      torrent_index.TorrentFile(
        name: "PackD/aaa.dat",
        size: 100_000,
        progress: 1.0,
        piece_range: #(0, 3),
      ),
      torrent_index.TorrentFile(
        name: "PackD/episode.bin",
        size: 4_194_304,
        progress: 1.0,
        piece_range: #(3, 131),
      ),
    ],
    piece_size: 32_768,
    piece_hashes: numbered_hashes(132),
  )
}

fn numbered_hashes(count: Int) -> List(String) {
  int.range(from: 0, to: count, with: [], run: fn(acc, index) {
    ["h" <> int.to_string(index), ..acc]
  })
  |> list.reverse
}

pub fn size_candidates_probes_an_interior_misaligned_file_test() {
  let index = torrent_index.build_index([misaligned_pack_entry()])

  assert torrent_index.size_candidates(index, 4_194_304)
    == [
      torrent_index.SizeCandidate(
        torrent_hash: "pack-d",
        piece_hash: "h4",
        probe_offset: 31_072,
        piece_size: 32_768,
      ),
    ]
}

pub fn size_candidates_probes_an_aligned_first_file_at_offset_zero_test() {
  let index = torrent_index.build_index([misaligned_pack_entry()])

  assert torrent_index.size_candidates(index, 100_000)
    == [
      torrent_index.SizeCandidate(
        torrent_hash: "pack-d",
        piece_hash: "h0",
        probe_offset: 0,
        piece_size: 32_768,
      ),
    ]
}

pub fn size_candidates_skips_a_file_with_no_fully_contained_piece_test() {
  // Second file is 30000 bytes: its first piece boundary is 31072 bytes in,
  // past the end of the file — no piece is fully its own, so it can't be
  // probed (and must not produce a bogus candidate).
  let entry =
    torrent_index.TorrentEntry(
      hash: "pack-e",
      name: "PackE",
      save_path: "/data/PackE",
      files: [
        torrent_index.TorrentFile(
          name: "PackE/aaa.dat",
          size: 100_000,
          progress: 1.0,
          piece_range: #(0, 3),
        ),
        torrent_index.TorrentFile(
          name: "PackE/tiny.bin",
          size: 30_000,
          progress: 1.0,
          piece_range: #(3, 3),
        ),
      ],
      piece_size: 32_768,
      piece_hashes: ["h0", "h1", "h2", "h3"],
    )
  let index = torrent_index.build_index([entry])

  assert torrent_index.size_candidates(index, 30_000) == []
}

pub fn size_candidates_skips_a_file_whose_piece_range_contradicts_offsets_test() {
  // Defensive: probe offsets are computed from cumulative sizes in listing
  // order. If the reported piece_range disagrees with that arithmetic, the
  // listing can't be trusted and no candidate must be produced.
  let entry =
    torrent_index.TorrentEntry(
      hash: "pack-f",
      name: "PackF",
      save_path: "/data/PackF",
      files: [
        torrent_index.TorrentFile(
          name: "PackF/aaa.dat",
          size: 100_000,
          progress: 1.0,
          piece_range: #(50, 53),
        ),
      ],
      piece_size: 32_768,
      piece_hashes: numbered_hashes(54),
    )
  let index = torrent_index.build_index([entry])

  assert torrent_index.size_candidates(index, 100_000) == []
}

pub fn hash_piece_at_matches_sha1_of_the_slice_test() {
  // sha1 of test/fixtures/sample.bin bytes [10, 30), precomputed with
  // hashlib — a probe into the middle of the file, not its first bytes.
  let assert Ok(hash) =
    piece_hasher.hash_piece_at("test/fixtures/sample.bin", 10, 20)
  assert hash == "53fbef2ce4dc5b5f79867dfca7dc84eccc100528"
}

pub fn verify_size_candidates_keeps_only_the_candidate_whose_piece_matches_test() {
  let matching =
    torrent_index.SizeCandidate(
      torrent_hash: "torrent-a",
      piece_hash: "53fbef2ce4dc5b5f79867dfca7dc84eccc100528",
      probe_offset: 10,
      piece_size: 20,
    )
  let wrong_content =
    torrent_index.SizeCandidate(
      torrent_hash: "torrent-b",
      piece_hash: "0000000000000000000000000000000000000000",
      probe_offset: 10,
      piece_size: 20,
    )

  assert torrent_index.verify_size_candidates("test/fixtures/sample.bin", [
      matching,
      wrong_content,
    ])
    == [matching]
}

pub fn hash_first_pieces_matches_shasum_test() {
  // test/fixtures/sample.bin is 30 bytes; sha1 verified with `shasum -a 1`.
  let assert Ok([hash]) =
    piece_hasher.hash_first_pieces(
      "test/fixtures/sample.bin",
      piece_hasher.PieceSize(30),
      1,
    )
  assert hash == "b67385b612cd52654273844aa0d8f35474821822"
}

pub fn find_first_match_tries_each_piece_size_until_one_matches_test() {
  // test/fixtures/sample.bin is 30 bytes, sha1 verified with `shasum -a 1`.
  // 999 is larger than the file, so hashing it fails and find_first_match
  // must move on to the next candidate size instead of giving up.
  let lookup = fn(hash) {
    case hash == "b67385b612cd52654273844aa0d8f35474821822" {
      True -> torrent_index.Matched("torrent-a", hash)
      False -> torrent_index.NoMatch
    }
  }

  let assert Ok(torrent_index.Matched(torrent_hash, _piece_hash)) =
    torrent_index.find_first_match(
      "test/fixtures/sample.bin",
      [999, 30],
      lookup,
    )
  assert torrent_hash == "torrent-a"
}

pub fn find_first_match_returns_error_when_no_size_matches_test() {
  let lookup = fn(_hash) { torrent_index.NoMatch }

  assert torrent_index.find_first_match(
      "test/fixtures/sample.bin",
      [30],
      lookup,
    )
    == Error(Nil)
}

pub fn relative_to_strips_the_base_directory_test() {
  assert torrent_index.relative_to(
      "/data/media",
      "/data/media/Show/episode.mkv",
    )
    == Ok("Show/episode.mkv")
}

pub fn relative_to_fails_when_path_is_outside_base_test() {
  assert torrent_index.relative_to("/data/media", "/data/downloads/episode.mkv")
    == Error(Nil)
}

pub fn relative_to_does_not_match_a_sibling_directory_with_the_same_prefix_test() {
  // Regression-shaped: "/data/media2" must not be treated as nested under
  // "/data/media" just because it shares a string prefix.
  assert torrent_index.relative_to("/data/media", "/data/media2/episode.mkv")
    == Error(Nil)
}

pub fn classify_ignores_directory_events_test() {
  assert fs_watcher.classify("/data/media/Show", ["created", "isdir"]) == None
}

pub fn classify_treats_a_write_without_the_isfile_flag_as_created_test() {
  // Verified live against a real FSEvents stream: `isfile` is not reliably
  // present, so classify can't require it (see fs_watcher.gleam).
  assert fs_watcher.classify("/data/media/episode.mkv", [
      "created", "modified", "xattrmod",
    ])
    == Some(fs_watcher.Created("/data/media/episode.mkv"))
}

pub fn classify_maps_removed_to_deleted_test() {
  assert fs_watcher.classify("/data/media/episode.mkv", ["removed"])
    == Some(fs_watcher.Deleted("/data/media/episode.mkv"))
}

pub fn classify_ignores_unrelated_flags_test() {
  assert fs_watcher.classify("/data/media/episode.mkv", ["inodemetamod"])
    == None
}

pub fn config_load_parses_a_full_config_test() {
  let assert Ok(loaded) = config.load("test/fixtures/valid_config.toml")

  assert loaded.qbittorrent.url == "http://localhost:8080"
  assert loaded.qbittorrent.username == "admin"
  assert loaded.qbittorrent.password == "secret"
  assert loaded.watch.paths == ["/data/media/movies", "/data/media/tv"]
  assert loaded.sync.recheck_delay_seconds == 5
  assert loaded.sync.min_file_size_mb == 10

  let assert Some(sonarr) = loaded.sonarr
  assert sonarr.url == "http://localhost:8989"
  assert sonarr.api_key == "sonarr-key"

  let assert Some(radarr) = loaded.radarr
  assert radarr.api_key == "radarr-key"
}

pub fn config_load_treats_missing_optional_sections_as_none_test() {
  let assert Ok(loaded) = config.load("test/fixtures/minimal_config.toml")

  assert loaded.sonarr == None
  assert loaded.radarr == None
}

pub fn config_load_fails_on_missing_file_test() {
  let assert Error(config.CannotReadFile(path, _reason)) =
    config.load("test/fixtures/does_not_exist.toml")
  assert path == "test/fixtures/does_not_exist.toml"
}

pub fn config_load_fails_on_malformed_toml_test() {
  let assert Error(config.InvalidToml(_reason)) =
    config.load("test/fixtures/malformed_config.toml")
}

pub fn config_load_fails_on_missing_required_field_test() {
  let assert Error(config.InvalidField(_reason)) =
    config.load("test/fixtures/missing_field_config.toml")
}
