import gleam/list

pub type HashError {
  CannotOpenFile(path: String)
  FileTooSmall(path: String)
}

pub type PieceSize {
  PieceSize(bytes: Int)
}

/// Hashes the first `count` pieces of a file, for comparison against a
/// candidate torrent's BitTorrent piece hashes. Reads each piece with a
/// direct pread, so a multi-GB media file is never loaded into memory.
pub fn hash_first_pieces(
  path: String,
  piece_size: PieceSize,
  count: Int,
) -> Result(List(String), HashError) {
  list.repeat(Nil, count)
  |> list.index_map(fn(_, index) { index })
  |> list.try_map(fn(index) {
    case hash_piece_ffi(path, index * piece_size.bytes, piece_size.bytes) {
      Ok(hex) -> Ok(hex)
      Error(CannotOpen) -> Error(CannotOpenFile(path))
      Error(TooSmall) -> Error(FileTooSmall(path))
    }
  })
}

type PreadError {
  CannotOpen
  TooSmall
}

@external(erlang, "piece_hasher_ffi", "hash_piece")
fn hash_piece_ffi(
  path: String,
  offset: Int,
  length: Int,
) -> Result(String, PreadError)
