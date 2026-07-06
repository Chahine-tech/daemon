import gleam/http.{Post}
import gleam/http/request
import gleam/httpc
import gleam/json
import gleam/result

pub type Credentials {
  Credentials(url: String, api_key: String)
}

pub type NotifyError {
  RequestFailed(httpc.HttpError)
  InvalidUrl(String)
  UnexpectedStatus(status: Int, body: String)
}

/// Asks Sonarr to rescan its library from disk after a resync — useful when
/// the rename that triggered it didn't come from Sonarr itself (a manual
/// move, another tool), so its view of file locations catches up. Verified
/// against a live Sonarr 4.x: RescanSeries completes successfully, while
/// the DownloadedEpisodesScan command previously used here reports 201 at
/// the HTTP layer but *fails* inside Sonarr (visible only in its command
/// history — it's the legacy drone-factory import, not a rescan).
pub fn notify_file_synced(
  credentials: Credentials,
) -> Result(Nil, NotifyError) {
  use base_request <- result.try(
    request.to(credentials.url <> "/api/v3/command")
    |> result.map_error(fn(_) { InvalidUrl(credentials.url) }),
  )

  let body = json.object([#("name", json.string("RescanSeries"))])

  let http_request =
    base_request
    |> request.set_method(Post)
    |> request.set_header("x-api-key", credentials.api_key)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(json.to_string(body))

  use http_response <- result.try(
    httpc.send(http_request) |> result.map_error(RequestFailed),
  )

  case http_response.status {
    200 | 201 | 202 -> Ok(Nil)
    status -> Error(UnexpectedStatus(status, http_response.body))
  }
}
