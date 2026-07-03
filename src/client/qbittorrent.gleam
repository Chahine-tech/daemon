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

  let req =
    base_request
    |> request.set_method(Post)
    |> request.set_header("content-type", "application/x-www-form-urlencoded")
    |> request.set_body(body)

  use resp <- result.try(httpc.send(req) |> result.map_error(RequestFailed))

  // Older qBittorrent returns 200 with a "Ok."/"Fails." body; 5.x returns
  // 204 with no body — verified against a live 5.2.2 container.
  case resp.status {
    200 | 204 -> extract_session(credentials.url, resp)
    status -> Error(AuthenticationRejected(status, resp.body))
  }
}

fn extract_session(
  base_url: String,
  resp: Response(String),
) -> Result(Session, QbittorrentError) {
  use set_cookie <- result.try(
    response.get_header(resp, "set-cookie")
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
  use resp <- result.try(get(session, "/api/v2/torrents/info"))
  decode_body(resp, decode.list(torrent_summary_decoder()))
}

/// GET /api/v2/torrents/files
pub fn torrent_files(
  session: Session,
  torrent_hash: String,
) -> Result(List(RemoteTorrentFile), QbittorrentError) {
  use resp <- result.try(get(
    session,
    "/api/v2/torrents/files?hash=" <> uri.percent_encode(torrent_hash),
  ))
  decode_body(resp, decode.list(remote_torrent_file_decoder()))
}

/// GET /api/v2/torrents/properties — piece_size isn't in torrents/info,
/// only here.
pub fn properties(
  session: Session,
  torrent_hash: String,
) -> Result(TorrentProperties, QbittorrentError) {
  use resp <- result.try(get(
    session,
    "/api/v2/torrents/properties?hash=" <> uri.percent_encode(torrent_hash),
  ))
  decode_body(resp, properties_decoder())
}

/// GET /api/v2/torrents/pieceHashes — the key to matching
pub fn piece_hashes(
  session: Session,
  torrent_hash: String,
) -> Result(List(String), QbittorrentError) {
  use resp <- result.try(get(
    session,
    "/api/v2/torrents/pieceHashes?hash=" <> uri.percent_encode(torrent_hash),
  ))
  decode_body(resp, decode.list(decode.string))
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
  use _resp <- result.try(post_form(
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
  use _resp <- result.try(post_form(
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
  use _resp <- result.try(post_form(session, "/api/v2/torrents/recheck", body))
  Ok(Nil)
}

pub type TorrentSummary {
  TorrentSummary(hash: String, name: String, save_path: String)
}

pub type RemoteTorrentFile {
  RemoteTorrentFile(name: String, size: Int, progress: Float)
}

pub type TorrentProperties {
  TorrentProperties(piece_size: Int)
}

fn torrent_summary_decoder() -> decode.Decoder(TorrentSummary) {
  use hash <- decode.field("hash", decode.string)
  use name <- decode.field("name", decode.string)
  use save_path <- decode.field("save_path", decode.string)
  decode.success(TorrentSummary(hash:, name:, save_path:))
}

fn remote_torrent_file_decoder() -> decode.Decoder(RemoteTorrentFile) {
  use name <- decode.field("name", decode.string)
  use size <- decode.field("size", decode.int)
  // qBittorrent serialises whole-number progress (e.g. complete files) as a
  // bare JSON int (`1`, not `1.0`), which decode.float alone rejects.
  use progress <- decode.field(
    "progress",
    decode.one_of(decode.float, or: [decode.int |> decode.map(int.to_float)]),
  )
  decode.success(RemoteTorrentFile(name:, size:, progress:))
}

fn properties_decoder() -> decode.Decoder(TorrentProperties) {
  use piece_size <- decode.field("piece_size", decode.int)
  decode.success(TorrentProperties(piece_size:))
}

fn get(
  session: Session,
  path: String,
) -> Result(Response(String), QbittorrentError) {
  use req <- result.try(authenticated_request(session, Get, path))
  send(req)
}

fn post_form(
  session: Session,
  path: String,
  body: String,
) -> Result(Response(String), QbittorrentError) {
  use req <- result.try(authenticated_request(session, Post, path))
  send(
    req
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

fn send(req: Request(String)) -> Result(Response(String), QbittorrentError) {
  use resp <- result.try(httpc.send(req) |> result.map_error(RequestFailed))
  case resp.status {
    200 -> Ok(resp)
    status -> Error(UnexpectedStatus(status, resp.body))
  }
}

fn decode_body(
  resp: Response(String),
  decoder: decode.Decoder(a),
) -> Result(a, QbittorrentError) {
  json.parse(resp.body, decoder) |> result.map_error(DecodeFailed)
}
