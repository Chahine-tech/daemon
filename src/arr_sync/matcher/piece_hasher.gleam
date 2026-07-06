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

/// Hashes `length` bytes of `path` starting at `offset` — for checking a
/// torrent piece that lies at a known position *inside* the file, when the
/// file doesn't start on a piece boundary (torrent_index's by-size
/// fallback). A read past the end of the file hashes the bytes that exist,
/// which is also how BitTorrent defines a torrent's short final piece.
pub fn hash_piece_at(
  path: String,
  offset: Int,
  length: Int,
) -> Result(String, HashError) {
  case hash_piece_ffi(path, offset, length) {
    Ok(hex) -> Ok(hex)
    Error(CannotOpen) -> Error(CannotOpenFile(path))
    Error(TooSmall) -> Error(FileTooSmall(path))
  }
}

type PreadError {
  CannotOpen
  TooSmall
}

@external(erlang, "arr_sync_piece_hasher_ffi", "hash_piece")
fn hash_piece_ffi(
  path: String,
  offset: Int,
  length: Int,
) -> Result(String, PreadError)
