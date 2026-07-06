pub type HashError {
  CannotOpenFile(path: String)
  FileTooSmall(path: String)
}

pub type PieceSize {
  PieceSize(bytes: Int)
}

/// How a torrent's piece hashes were computed: flat SHA1 for BitTorrent v1
/// (and the v1 side of hybrids), SHA256 merkle roots over 16 KiB blocks for
/// v2 (BEP 52). The two never collide in an index — v1 hex is 40 chars,
/// v2 is 64.
pub type HashAlgorithm {
  Sha1Flat
  Sha256Merkle
}

/// Hashes the first piece of a file, for comparison against a candidate
/// torrent's piece hashes. Reads only that piece with a direct pread, so a
/// multi-GB media file is never loaded into memory.
pub fn hash_first_piece(
  path: String,
  piece_size: PieceSize,
  algorithm: HashAlgorithm,
) -> Result(String, HashError) {
  let result = case algorithm {
    Sha1Flat -> hash_piece_ffi(path, 0, piece_size.bytes)
    Sha256Merkle -> hash_piece_v2_ffi(path, 0, piece_size.bytes)
  }
  case result {
    Ok(hex) -> Ok(hex)
    Error(CannotOpen) -> Error(CannotOpenFile(path))
    Error(TooSmall) -> Error(FileTooSmall(path))
  }
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

@external(erlang, "arr_sync_piece_hasher_ffi", "hash_piece_v2")
fn hash_piece_v2_ffi(
  path: String,
  offset: Int,
  length: Int,
) -> Result(String, PreadError)
