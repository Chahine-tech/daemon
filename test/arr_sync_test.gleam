import gleeunit
import matcher/piece_hasher
import matcher/torrent_index

pub fn main() -> Nil {
  gleeunit.main()
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
    == torrent_index.Matched("torrent-a")
}

pub fn find_match_returns_no_match_for_an_unknown_piece_hash_test() {
  let index = torrent_index.build_index([sample_entry("torrent-a", ["hash-1"])])

  assert torrent_index.find_match(index, "unknown") == torrent_index.NoMatch
}

pub fn find_match_returns_ambiguous_when_two_torrents_share_a_piece_hash_test() {
  let index =
    torrent_index.build_index([
      sample_entry("torrent-a", ["shared-hash"]),
      sample_entry("torrent-b", ["shared-hash"]),
    ])

  let assert torrent_index.Ambiguous(candidates) =
    torrent_index.find_match(index, "shared-hash")

  assert list_contains_both(candidates, "torrent-a", "torrent-b")
}

fn list_contains_both(candidates: List(String), a: String, b: String) -> Bool {
  case candidates {
    [x, y] -> { x == a && y == b } || { x == b && y == a }
    _ -> False
  }
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

pub fn hello_world_test() {
  let name = "Joe"
  let greeting = "Hello, " <> name <> "!"

  assert greeting == "Hello, Joe!"
}
