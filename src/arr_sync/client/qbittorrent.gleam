import gleam/bit_array
import gleam/dynamic/decode
import gleam/http.{type Method, Get, Post}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/int
import gleam/json
import gleam/result
import gleam/string
import gleam/uri

pub type Credentials {
  Credentials(url: String, username: String, password: String)
}

pub type Session {
  Session(base_url: String, cookie: String)
}

pub type QbittorrentError {
  RequestFailed(httpc.HttpError)
  // gleam_httpc doesn't normalise every httpc-level error into a typed
  // Result — some (e.g. socket_closed_remotely, seen live when qBittorrent
  // restarts mid-request) raise an uncaught Erlang exception instead. Every
  // HTTP call in this module goes through safe_call, which catches that and
  // surfaces it here instead of crashing the caller (the torrent_index
  // actor, which would otherwise crash-loop the whole daemon past its
  // supervisor's restart budget — verified live).
  ConnectionLost(String)
  InvalidUrl(String)
  AuthenticationRejected(status: Int, body: String)
  MissingSessionCookie
  UnexpectedStatus(status: Int, body: String)
  DecodeFailed(json.DecodeError)
}

pub fn login(credentials: Credentials) -> Result(Session, QbittorrentError) {
  use base_request <- result.try(
    request.to(credentials.url <> "/api/v2/auth/login")
    |> result.map_error(fn(_) { InvalidUrl(credentials.url) }),
  )

  let body =
    "username="
    <> uri.percent_encode(credentials.username)
    <> "&password="
    <> uri.percent_encode(credentials.password)

  let http_request =
    base_request
    |> request.set_method(Post)
    |> request.set_header("content-type", "application/x-www-form-urlencoded")
    |> request.set_body(body)

  use http_response <- result.try(
    safe_call(fn() {
      httpc.send(http_request) |> result.map_error(RequestFailed)
    }),
  )

  // Older qBittorrent returns 200 with a "Ok."/"Fails." body; 5.x returns
  // 204 with no body — verified against a live 5.2.2 container.
  case http_response.status {
    200 | 204 -> extract_session(credentials.url, http_response)
    status -> Error(AuthenticationRejected(status, http_response.body))
  }
}

fn extract_session(
  base_url: String,
  http_response: Response(String),
) -> Result(Session, QbittorrentError) {
  use set_cookie <- result.try(
    response.get_header(http_response, "set-cookie")
    |> result.replace_error(MissingSessionCookie),
  )

  // qBittorrent returns "SID=<value>; path=/; HttpOnly" — only the first
  // segment (the key=value pair) is needed for subsequent requests.
  case string.split(set_cookie, ";") {
    [session_pair, ..] -> Ok(Session(base_url:, cookie: session_pair))
    [] -> Error(MissingSessionCookie)
  }
}

/// GET /api/v2/torrents/info
pub fn list_torrents(
  session: Session,
) -> Result(List(TorrentSummary), QbittorrentError) {
  use http_response <- result.try(get(session, "/api/v2/torrents/info"))
  decode_body(http_response, decode.list(torrent_summary_decoder()))
}

/// GET /api/v2/torrents/files
pub fn torrent_files(
  session: Session,
  torrent_hash: String,
) -> Result(List(RemoteTorrentFile), QbittorrentError) {
  use http_response <- result.try(get(
    session,
    "/api/v2/torrents/files?hash=" <> uri.percent_encode(torrent_hash),
  ))
  decode_body(http_response, decode.list(remote_torrent_file_decoder()))
}

/// GET /api/v2/torrents/properties — piece_size isn't in torrents/info,
/// only here.
pub fn properties(
  session: Session,
  torrent_hash: String,
) -> Result(TorrentProperties, QbittorrentError) {
  use http_response <- result.try(get(
    session,
    "/api/v2/torrents/properties?hash=" <> uri.percent_encode(torrent_hash),
  ))
  decode_body(http_response, properties_decoder())
}

/// GET /api/v2/torrents/pieceHashes — the key to matching
pub fn piece_hashes(
  session: Session,
  torrent_hash: String,
) -> Result(List(String), QbittorrentError) {
  use http_response <- result.try(get(
    session,
    "/api/v2/torrents/pieceHashes?hash=" <> uri.percent_encode(torrent_hash),
  ))
  decode_body(http_response, decode.list(decode.string))
}

/// GET /api/v2/torrents/export — the torrent's original .torrent file, raw
/// bencode bytes. The only way to get real piece hashes for a pure
/// BitTorrent v2 torrent, whose pieceHashes endpoint is broken (see
/// properties_decoder's doc comment).
pub fn export_torrent(
  session: Session,
  torrent_hash: String,
) -> Result(BitArray, QbittorrentError) {
  use http_request <- result.try(authenticated_request(
    session,
    Get,
    "/api/v2/torrents/export?hash=" <> uri.percent_encode(torrent_hash),
  ))
  use http_response <- result.try(
    safe_call(fn() {
      http_request
      |> request.set_body(<<>>)
      |> httpc.send_bits
      |> result.map_error(RequestFailed)
    }),
  )
  case http_response.status {
    200 -> Ok(http_response.body)
    status ->
      Error(UnexpectedStatus(
        status,
        bit_array.to_string(http_response.body) |> result.unwrap(""),
      ))
  }
}

/// POST /api/v2/torrents/setLocation — moves the torrent to a different
/// save_path (directory). Does NOT update the filename qBittorrent expects
/// internally: a same-directory rename needs rename_file below instead, or
/// as well if both the directory and the filename changed.
pub fn set_location(
  session: Session,
  torrent_hash: String,
  new_location: String,
) -> Result(Nil, QbittorrentError) {
  let body =
    "hashes="
    <> uri.percent_encode(torrent_hash)
    <> "&location="
    <> uri.percent_encode(new_location)
  use _http_response <- result.try(post_form(
    session,
    "/api/v2/torrents/setLocation",
    body,
  ))
  Ok(Nil)
}

/// POST /api/v2/torrents/renameFile — old_path/new_path are relative to the
/// torrent's own root, not absolute filesystem paths. This is what actually
/// fixes a Sonarr/Radarr rename; verified live: without it, setLocation +
/// recheck alone leaves the torrent looking for the old filename and it
/// drops to 0% instead of resyncing.
pub fn rename_file(
  session: Session,
  torrent_hash: String,
  old_path: String,
  new_path: String,
) -> Result(Nil, QbittorrentError) {
  let body =
    "hash="
    <> uri.percent_encode(torrent_hash)
    <> "&oldPath="
    <> uri.percent_encode(old_path)
    <> "&newPath="
    <> uri.percent_encode(new_path)
  use _http_response <- result.try(post_form(
    session,
    "/api/v2/torrents/renameFile",
    body,
  ))
  Ok(Nil)
}

/// POST /api/v2/torrents/recheck
pub fn recheck(
  session: Session,
  torrent_hash: String,
) -> Result(Nil, QbittorrentError) {
  let body = "hashes=" <> uri.percent_encode(torrent_hash)
  use _http_response <- result.try(post_form(
    session,
    "/api/v2/torrents/recheck",
    body,
  ))
  Ok(Nil)
}

pub type TorrentSummary {
  TorrentSummary(hash: String, name: String, save_path: String)
}

pub type RemoteTorrentFile {
  RemoteTorrentFile(
    name: String,
    size: Int,
    progress: Float,
    piece_range: #(Int, Int),
  )
}

pub type TorrentProperties {
  // infohash_v1 is "" for a pure BitTorrent v2 torrent — see
  // properties_decoder's doc comment for why that matters here.
  TorrentProperties(piece_size: Int, infohash_v1: String)
}

@internal
pub fn torrent_summary_decoder() -> decode.Decoder(TorrentSummary) {
  use hash <- decode.field("hash", decode.string)
  use name <- decode.field("name", decode.string)
  use save_path <- decode.field("save_path", decode.string)
  decode.success(TorrentSummary(hash:, name:, save_path:))
}

@internal
pub fn remote_torrent_file_decoder() -> decode.Decoder(RemoteTorrentFile) {
  use name <- decode.field("name", decode.string)
  use size <- decode.field("size", decode.int)
  // qBittorrent serialises whole-number progress (e.g. complete files) as a
  // bare JSON int (`1`, not `1.0`), which decode.float alone rejects.
  use progress <- decode.field(
    "progress",
    decode.one_of(decode.float, or: [decode.int |> decode.map(int.to_float)]),
  )
  // [start, end] piece indices this file spans — verified live: qBittorrent
  // computes this for us, sparing us cumulative file-offset arithmetic.
  use piece_range <- decode.field("piece_range", piece_range_decoder())
  decode.success(RemoteTorrentFile(name:, size:, progress:, piece_range:))
}

fn piece_range_decoder() -> decode.Decoder(#(Int, Int)) {
  use values <- decode.then(decode.list(decode.int))
  case values {
    [start, end] -> decode.success(#(start, end))
    _ -> decode.failure(#(0, 0), "piece_range")
  }
}

/// infohash_v1 is empty for a pure BitTorrent v2 torrent, non-empty for a v1
/// or hybrid (v1+v2) one. Verified live against qBittorrent 5.2.2: for a
/// hybrid torrent, `torrents/pieceHashes` returns its v1 SHA1 hashes
/// unchanged (byte-identical to a plain v1 torrent of the same content) —
/// already matched correctly by the existing SHA1 piece hasher, no v2-
/// specific code needed. For a pure v2 torrent, `torrents/pieceHashes`
/// doesn't return real hashes at all: it returns the raw bencoded bytes of
/// the torrent's own `info` dict, sliced into 20-byte chunks and hex-encoded
/// as if they were SHA1 hashes (confirmed by decoding the hex — it's
/// literally `d9:file treed13:...`, the info dict's own bencode). This
/// field is how torrent_index tells the two cases apart and skips the
/// latter instead of indexing garbage.
@internal
pub fn properties_decoder() -> decode.Decoder(TorrentProperties) {
  use piece_size <- decode.field("piece_size", decode.int)
  use infohash_v1 <- decode.field("infohash_v1", decode.string)
  decode.success(TorrentProperties(piece_size:, infohash_v1:))
}

fn get(
  session: Session,
  path: String,
) -> Result(Response(String), QbittorrentError) {
  use http_request <- result.try(authenticated_request(session, Get, path))
  send(http_request)
}

fn post_form(
  session: Session,
  path: String,
  body: String,
) -> Result(Response(String), QbittorrentError) {
  use http_request <- result.try(authenticated_request(session, Post, path))
  send(
    http_request
    |> request.set_header("content-type", "application/x-www-form-urlencoded")
    |> request.set_body(body),
  )
}

fn authenticated_request(
  session: Session,
  method: Method,
  path: String,
) -> Result(Request(String), QbittorrentError) {
  use base_request <- result.try(
    request.to(session.base_url <> path)
    |> result.map_error(fn(_) { InvalidUrl(session.base_url) }),
  )
  Ok(
    base_request
    |> request.set_method(method)
    |> request.set_header("cookie", session.cookie),
  )
}

fn send(
  http_request: Request(String),
) -> Result(Response(String), QbittorrentError) {
  use http_response <- result.try(
    safe_call(fn() {
      httpc.send(http_request) |> result.map_error(RequestFailed)
    }),
  )
  case http_response.status {
    200 -> Ok(http_response)
    status -> Error(UnexpectedStatus(status, http_response.body))
  }
}

@external(erlang, "arr_sync_qbittorrent_ffi", "safe_call")
fn safe_call(
  thunk: fn() -> Result(a, QbittorrentError),
) -> Result(a, QbittorrentError)

fn decode_body(
  http_response: Response(String),
  decoder: decode.Decoder(a),
) -> Result(a, QbittorrentError) {
  json.parse(http_response.body, decoder)
  |> result.map_error(DecodeFailed)
}
