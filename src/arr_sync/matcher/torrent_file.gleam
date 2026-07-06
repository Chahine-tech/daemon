//// Parses a raw .torrent file (bencode) to extract what BitTorrent v2
//// matching needs: the SHA256 piece hashes qBittorrent's own pieceHashes
//// endpoint is unable to report for pure v2 torrents (see CONTRIBUTING.md).
//// Fed by `torrents/export`, which returns the torrent's original bytes.

import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string

pub type Bencode {
  BString(BitArray)
  BInt(Int)
  BList(List(Bencode))
  // Keys stay raw bytes: piece layers are keyed by 32-byte hashes, not text.
  BDict(List(#(BitArray, Bencode)))
}

pub fn parse(data: BitArray) -> Result(Bencode, Nil) {
  use #(value, _rest) <- result.map(parse_value(data))
  value
}

fn parse_value(data: BitArray) -> Result(#(Bencode, BitArray), Nil) {
  case data {
    <<"i", rest:bits>> -> parse_int(rest, 0, 1)
    <<"l", rest:bits>> -> parse_list(rest, [])
    <<"d", rest:bits>> -> parse_dict(rest, [])
    _ -> parse_string(data)
  }
}

fn parse_int(
  data: BitArray,
  accumulator: Int,
  sign: Int,
) -> Result(#(Bencode, BitArray), Nil) {
  case data {
    <<"-", rest:bits>> if accumulator == 0 -> parse_int(rest, accumulator, -1)
    <<"e", rest:bits>> -> Ok(#(BInt(accumulator * sign), rest))
    <<digit:8, rest:bits>> if digit >= 48 && digit <= 57 ->
      parse_int(rest, accumulator * 10 + digit - 48, sign)
    _ -> Error(Nil)
  }
}

fn parse_list(
  data: BitArray,
  items: List(Bencode),
) -> Result(#(Bencode, BitArray), Nil) {
  case data {
    <<"e", rest:bits>> -> Ok(#(BList(list.reverse(items)), rest))
    _ -> {
      use #(item, rest) <- result.try(parse_value(data))
      parse_list(rest, [item, ..items])
    }
  }
}

fn parse_dict(
  data: BitArray,
  entries: List(#(BitArray, Bencode)),
) -> Result(#(Bencode, BitArray), Nil) {
  case data {
    <<"e", rest:bits>> -> Ok(#(BDict(list.reverse(entries)), rest))
    _ -> {
      use #(key, rest) <- result.try(parse_string(data))
      use key_bytes <- result.try(case key {
        BString(bytes) -> Ok(bytes)
        _ -> Error(Nil)
      })
      use #(value, rest) <- result.try(parse_value(rest))
      parse_dict(rest, [#(key_bytes, value), ..entries])
    }
  }
}

fn parse_string(data: BitArray) -> Result(#(Bencode, BitArray), Nil) {
  parse_string_length(data, 0)
}

fn parse_string_length(
  data: BitArray,
  length: Int,
) -> Result(#(Bencode, BitArray), Nil) {
  case data {
    <<digit:8, rest:bits>> if digit >= 48 && digit <= 57 ->
      parse_string_length(rest, length * 10 + digit - 48)
    <<":", rest:bits>> ->
      case rest {
        <<value:bytes-size(length), remaining:bits>> ->
          Ok(#(BString(value), remaining))
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// One file of a v2 torrent: its path inside the torrent (no torrent-name
/// prefix), its size, and its SHA256 piece hashes from the piece layers —
/// empty for a file no larger than one piece, which has no layer entry
/// (its `pieces root` is not comparable to a piece hash, so such files
/// can't be piece-matched; they're at most `piece length` bytes anyway).
pub type V2File {
  V2File(path: String, size: Int, piece_hashes: List(String))
}

pub type V2Metadata {
  V2Metadata(name: String, piece_length: Int, files: List(V2File))
}

pub fn parse_v2(data: BitArray) -> Result(V2Metadata, Nil) {
  use torrent <- result.try(parse(data))
  use info <- result.try(get(torrent, "info"))
  use meta_version <- result.try(get_int(info, "meta version"))
  use <- require(meta_version == 2)
  use piece_length <- result.try(get_int(info, "piece length"))
  use name <- result.try(get_text(info, "name"))
  use file_tree <- result.try(get(info, "file tree"))
  // A torrent may legitimately have no piece layers at all (every file no
  // larger than one piece) — treat it as an empty dict.
  let piece_layers = get(torrent, "piece layers") |> result.unwrap(BDict([]))
  use files <- result.map(walk_file_tree(file_tree, [], piece_layers))
  V2Metadata(name:, piece_length:, files:)
}

fn walk_file_tree(
  tree: Bencode,
  path_segments: List(String),
  piece_layers: Bencode,
) -> Result(List(V2File), Nil) {
  use entries <- result.try(case tree {
    BDict(entries) -> Ok(entries)
    _ -> Error(Nil)
  })
  entries
  |> list.try_map(fn(entry) {
    let #(key, value) = entry
    case key {
      // A "" key marks a leaf: its value holds length + pieces root.
      <<>> -> {
        use size <- result.try(get_int(value, "length"))
        use root <- result.try(get_bytes(value, "pieces root"))
        let path = path_segments |> list.reverse |> string.join("/")
        let piece_hashes = layer_hashes(piece_layers, root) |> result.unwrap([])
        Ok([V2File(path:, size:, piece_hashes:)])
      }
      _ -> {
        use segment <- result.try(
          bit_array.to_string(key) |> result.replace_error(Nil),
        )
        walk_file_tree(value, [segment, ..path_segments], piece_layers)
      }
    }
  })
  |> result.map(list.flatten)
}

fn layer_hashes(
  piece_layers: Bencode,
  root: BitArray,
) -> Result(List(String), Nil) {
  use entries <- result.try(case piece_layers {
    BDict(entries) -> Ok(entries)
    _ -> Error(Nil)
  })
  use #(_key, value) <- result.try(
    list.find(entries, fn(entry) { entry.0 == root }),
  )
  case value {
    BString(bytes) -> chunk_hashes(bytes, [])
    _ -> Error(Nil)
  }
}

fn chunk_hashes(
  bytes: BitArray,
  hashes: List(String),
) -> Result(List(String), Nil) {
  case bytes {
    <<>> -> Ok(list.reverse(hashes))
    <<hash:bytes-size(32), rest:bits>> ->
      chunk_hashes(rest, [
        string.lowercase(bit_array.base16_encode(hash)),
        ..hashes
      ])
    _ -> Error(Nil)
  }
}

fn get(value: Bencode, key: String) -> Result(Bencode, Nil) {
  use entries <- result.try(case value {
    BDict(entries) -> Ok(entries)
    _ -> Error(Nil)
  })
  let key = bit_array.from_string(key)
  list.find(entries, fn(entry) { entry.0 == key })
  |> result.map(fn(entry) { entry.1 })
}

fn get_int(value: Bencode, key: String) -> Result(Int, Nil) {
  case get(value, key) {
    Ok(BInt(number)) -> Ok(number)
    _ -> Error(Nil)
  }
}

fn get_bytes(value: Bencode, key: String) -> Result(BitArray, Nil) {
  case get(value, key) {
    Ok(BString(bytes)) -> Ok(bytes)
    _ -> Error(Nil)
  }
}

fn get_text(value: Bencode, key: String) -> Result(String, Nil) {
  use bytes <- result.try(get_bytes(value, key))
  bit_array.to_string(bytes) |> result.replace_error(Nil)
}

fn require(condition: Bool, next: fn() -> Result(a, Nil)) -> Result(a, Nil) {
  case condition {
    True -> next()
    False -> Error(Nil)
  }
}
