import arr_sync/client/qbittorrent
import arr_sync/config
import arr_sync/matcher/piece_hasher
import arr_sync/matcher/torrent_file
import arr_sync/matcher/torrent_index
import arr_sync/paths
import arr_sync/watcher/fs_watcher
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import simplifile

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
    algorithm: piece_hasher.Sha1Flat,
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
      algorithm: piece_hasher.Sha1Flat,
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
    algorithm: piece_hasher.Sha1Flat,
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
      algorithm: piece_hasher.Sha1Flat,
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
      algorithm: piece_hasher.Sha1Flat,
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

pub fn hash_first_piece_matches_shasum_test() {
  // test/fixtures/sample.bin is 30 bytes; sha1 verified with `shasum -a 1`.
  let assert Ok(hash) =
    piece_hasher.hash_first_piece(
      "test/fixtures/sample.bin",
      piece_hasher.PieceSize(30),
      piece_hasher.Sha1Flat,
    )
  assert hash == "b67385b612cd52654273844aa0d8f35474821822"
}

pub fn find_first_match_tries_each_probe_until_one_matches_test() {
  // test/fixtures/sample.bin is 30 bytes, sha1 verified with `shasum -a 1`.
  // 999 is larger than the file, so hashing it fails and find_first_match
  // must move on to the next candidate probe instead of giving up.
  let lookup = fn(hash) {
    case hash == "b67385b612cd52654273844aa0d8f35474821822" {
      True -> torrent_index.Matched("torrent-a", hash)
      False -> torrent_index.NoMatch
    }
  }

  let assert Ok(torrent_index.Matched(torrent_hash, _piece_hash)) =
    torrent_index.find_first_match(
      "test/fixtures/sample.bin",
      [
        torrent_index.Probe(piece_size: 999, algorithm: piece_hasher.Sha1Flat),
        torrent_index.Probe(piece_size: 30, algorithm: piece_hasher.Sha1Flat),
      ],
      lookup,
    )
  assert torrent_hash == "torrent-a"
}

pub fn find_first_match_returns_error_when_no_probe_matches_test() {
  let lookup = fn(_hash) { torrent_index.NoMatch }

  assert torrent_index.find_first_match(
      "test/fixtures/sample.bin",
      [torrent_index.Probe(piece_size: 30, algorithm: piece_hasher.Sha1Flat)],
      lookup,
    )
    == Error(Nil)
}

pub fn parse_v2_extracts_piece_hashes_from_a_real_single_file_torrent_test() {
  // test/fixtures/v2_single_file.torrent was created and exported by a real
  // qBittorrent 5.2.2 (torrents/export); expected values cross-checked with
  // an independent python bencode decoder.
  let assert Ok(raw) =
    simplifile.read_bits("test/fixtures/v2_single_file.torrent")
  let assert Ok(metadata) = torrent_file.parse_v2(raw)

  assert metadata.name == "v2movie.bin"
  assert metadata.piece_length == 32_768
  let assert [file] = metadata.files
  assert file.path == "v2movie.bin"
  assert file.size == 5_242_880
  assert list.length(file.piece_hashes) == 160
  let assert Ok(first_hash) = list.first(file.piece_hashes)
  assert first_hash
    == "0ba2a1950c8339cbb80071438448a00e033cc0b174c3e6857e4bdfd45057b571"
}

pub fn parse_v2_extracts_both_files_from_a_real_multi_file_torrent_test() {
  let assert Ok(raw) =
    simplifile.read_bits("test/fixtures/v2_multi_file.torrent")
  let assert Ok(metadata) = torrent_file.parse_v2(raw)

  assert metadata.name == "PackV2"
  assert metadata.piece_length == 16_384
  let assert [episode, small] =
    list.sort(metadata.files, fn(a, b) { string.compare(a.path, b.path) })
  assert episode.path == "episode.bin"
  assert episode.size == 2_097_152
  assert list.length(episode.piece_hashes) == 128
  assert small.path == "small.dat"
  assert small.size == 50_000
  assert list.length(small.piece_hashes) == 4
}

pub fn parse_v2_rejects_a_v1_torrent_test() {
  // A v1 torrent has no "meta version" — parse_v2 must refuse it rather
  // than fabricate an entry with no v2 hashes.
  let v1 = <<
    "d4:infod4:name1:a12:piece lengthi32768e6:pieces20:aaaaaaaaaaaaaaaaaaaaee":utf8,
  >>
  assert torrent_file.parse_v2(v1) == Error(Nil)
}

pub fn hash_first_piece_v2_computes_the_merkle_root_of_a_partial_block_test() {
  // A 30-byte file with a 16 KiB piece is a single partial block, so the
  // v2 piece hash is just sha256 of the file — precomputed with hashlib.
  let assert Ok(hash) =
    piece_hasher.hash_first_piece(
      "test/fixtures/sample.bin",
      piece_hasher.PieceSize(16_384),
      piece_hasher.Sha256Merkle,
    )
  assert hash
    == "a528389f78049f96c5c57e2aed2570a4d1ed840e7a31c1faeedca695aca63cd7"
}

pub fn hash_first_piece_v2_pairs_two_blocks_into_a_merkle_root_test() {
  // 20000 bytes with a 32 KiB piece = one full 16 KiB block + one partial:
  // root = sha256(sha256(block0) <> sha256(block1)) — precomputed with
  // hashlib.
  let assert Ok(hash) =
    piece_hasher.hash_first_piece(
      "test/fixtures/v2_two_blocks.bin",
      piece_hasher.PieceSize(32_768),
      piece_hasher.Sha256Merkle,
    )
  assert hash
    == "77800aa9c58a128513d1d3596bd8f37dde66a062764391a95933412e2d30e753"
}

fn v2_metadata() -> torrent_file.V2Metadata {
  // Mirrors the real PackV2 layout (v2_multi_file.torrent), with short fake
  // hashes: episode.bin pieces [0,127], small.dat pieces [128,131].
  torrent_file.V2Metadata(name: "PackV2", piece_length: 16_384, files: [
    torrent_file.V2File(
      path: "episode.bin",
      size: 2_097_152,
      piece_hashes: numbered_hashes(128),
    ),
    torrent_file.V2File(path: "small.dat", size: 50_000, piece_hashes: [
      "s0", "s1", "s2", "s3",
    ]),
  ])
}

fn v2_api_file(
  name: String,
  size: Int,
  piece_range: #(Int, Int),
) -> qbittorrent.RemoteTorrentFile {
  qbittorrent.RemoteTorrentFile(name:, size:, progress: 1.0, piece_range:)
}

pub fn flatten_v2_piece_hashes_lays_files_out_on_global_numbering_test() {
  let assert Ok(flattened) =
    torrent_index.flatten_v2_piece_hashes(v2_metadata(), [
      v2_api_file("PackV2/small.dat", 50_000, #(128, 131)),
      v2_api_file("PackV2/episode.bin", 2_097_152, #(0, 127)),
    ])

  assert list.length(flattened) == 132
  let assert Ok(first) = list.first(flattened)
  assert first == "h0"
  assert list.drop(flattened, 128) == ["s0", "s1", "s2", "s3"]
}

pub fn flatten_v2_piece_hashes_rejects_a_gap_in_piece_ranges_test() {
  assert torrent_index.flatten_v2_piece_hashes(v2_metadata(), [
      v2_api_file("PackV2/episode.bin", 2_097_152, #(0, 127)),
      v2_api_file("PackV2/small.dat", 50_000, #(129, 132)),
    ])
    == Error(Nil)
}

pub fn flatten_v2_piece_hashes_rejects_a_hash_count_mismatch_test() {
  assert torrent_index.flatten_v2_piece_hashes(v2_metadata(), [
      v2_api_file("PackV2/episode.bin", 2_097_152, #(0, 126)),
      v2_api_file("PackV2/small.dat", 50_000, #(127, 130)),
    ])
    == Error(Nil)
}

pub fn flatten_v2_piece_hashes_holds_a_sub_piece_file_slot_with_a_placeholder_test() {
  // A file no larger than one piece has no piece layer; its single piece
  // slot must be held so following files keep their numbering.
  let metadata =
    torrent_file.V2Metadata(name: "PackW", piece_length: 16_384, files: [
      torrent_file.V2File(path: "tiny.nfo", size: 500, piece_hashes: []),
      torrent_file.V2File(path: "episode.bin", size: 32_768, piece_hashes: [
        "e0", "e1",
      ]),
    ])
  let assert Ok(flattened) =
    torrent_index.flatten_v2_piece_hashes(metadata, [
      v2_api_file("PackW/tiny.nfo", 500, #(0, 0)),
      v2_api_file("PackW/episode.bin", 32_768, #(1, 2)),
    ])

  assert flattened == ["", "e0", "e1"]
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

fn sample_mappings() -> List(paths.PathMapping) {
  [
    paths.PathMapping(remote: "/downloads", local: "/data/torrents"),
    paths.PathMapping(remote: "/data/media", local: "/mnt/media"),
  ]
}

pub fn to_local_swaps_a_mapped_prefix_test() {
  assert paths.to_local(sample_mappings(), "/downloads/Show/episode.mkv")
    == "/data/torrents/Show/episode.mkv"
}

pub fn to_local_leaves_an_unmapped_path_unchanged_test() {
  assert paths.to_local(sample_mappings(), "/elsewhere/file.mkv")
    == "/elsewhere/file.mkv"
}

pub fn to_local_does_not_match_a_sibling_directory_with_the_same_prefix_test() {
  // "/downloads2" must not be rewritten just because it shares a string
  // prefix with the "/downloads" mapping.
  assert paths.to_local(sample_mappings(), "/downloads2/file.mkv")
    == "/downloads2/file.mkv"
}

pub fn to_local_maps_the_prefix_itself_test() {
  assert paths.to_local(sample_mappings(), "/data/media") == "/mnt/media"
}

pub fn to_remote_swaps_back_the_local_prefix_test() {
  assert paths.to_remote(sample_mappings(), "/mnt/media/Show")
    == "/data/media/Show"
}

pub fn canonicalize_resolves_a_symlinked_directory_test() {
  // Built at runtime so the test works on any OS: real_dir/file.bin reached
  // through link_dir -> real_dir must canonicalize to the real path.
  let base = "test/fixtures/canonicalize_scratch"
  let _ = simplifile.delete(base)
  let assert Ok(Nil) = simplifile.create_directory_all(base <> "/real_dir")
  let assert Ok(Nil) =
    simplifile.create_symlink(to: "real_dir", from: base <> "/link_dir")

  let canonical = paths.canonicalize(base <> "/link_dir/file.bin")

  let assert Ok(Nil) = simplifile.delete(base)
  assert canonical == base <> "/real_dir/file.bin"
}

pub fn canonicalize_leaves_a_plain_path_unchanged_test() {
  assert paths.canonicalize("/no/such/path/anywhere.bin")
    == "/no/such/path/anywhere.bin"
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
  assert loaded.path_mappings
    == [paths.PathMapping(remote: "/downloads", local: "/data/torrents")]

  let assert Some(sonarr) = loaded.sonarr
  assert sonarr.url == "http://localhost:8989"
  assert sonarr.api_key == "sonarr-key"

  let assert Some(radarr) = loaded.radarr
  assert radarr.api_key == "radarr-key"
}

pub fn config_load_prefers_the_password_env_var_over_the_file_test() {
  set_env("QBITTORRENT_PASSWORD", "from-env")
  let loaded = config.load("test/fixtures/valid_config.toml")
  unset_env("QBITTORRENT_PASSWORD")

  let assert Ok(loaded) = loaded
  assert loaded.qbittorrent.password == "from-env"
}

pub fn config_load_accepts_a_missing_password_field_when_env_var_is_set_test() {
  set_env("QBITTORRENT_PASSWORD", "from-env")
  let loaded = config.load("test/fixtures/env_password_config.toml")
  unset_env("QBITTORRENT_PASSWORD")

  let assert Ok(loaded) = loaded
  assert loaded.qbittorrent.password == "from-env"
}

pub fn config_load_ignores_an_empty_password_env_var_test() {
  // docker compose substitutes an undefined variable as "" — that must not
  // shadow the real password in the file.
  set_env("QBITTORRENT_PASSWORD", "")
  let loaded = config.load("test/fixtures/valid_config.toml")
  unset_env("QBITTORRENT_PASSWORD")

  let assert Ok(loaded) = loaded
  assert loaded.qbittorrent.password == "secret"
}

@external(erlang, "arr_sync_test_ffi", "set_env")
fn set_env(name: String, value: String) -> Nil

@external(erlang, "arr_sync_test_ffi", "unset_env")
fn unset_env(name: String) -> Nil

pub fn config_load_treats_missing_optional_sections_as_none_test() {
  let assert Ok(loaded) = config.load("test/fixtures/minimal_config.toml")

  assert loaded.sonarr == None
  assert loaded.radarr == None
  assert loaded.path_mappings == []
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
