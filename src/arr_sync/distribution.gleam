import arr_sync/matcher/torrent_index
import gleam/erlang/process
import gleam/result
import gleam/string
import simplifile

const cookie_file = ".arr-sync-cookie"

pub type StatusReport {
  StatusReport(
    torrent_count: Int,
    piece_sizes: List(Int),
    resync_success_count: Int,
    resync_failure_count: Int,
  )
}

pub type DistributionError {
  CookieFileError(simplifile.FileError)
  CookieWriteError(String)
  StartFailed(String)
  DaemonUnreachable
  RpcFailed(String)
}

/// The Name torrent_index registers under. Fixed (no random suffix, unlike
/// process.new_name/1) so query_status, invoked over RPC by a separate CLI
/// node, can reconstruct the exact same Name and find the running actor.
pub fn torrent_index_name() -> process.Name(torrent_index.Message) {
  fixed_name("arr_sync_torrent_index")
}

/// Reads the cookie used to authenticate distributed Erlang connections
/// between the daemon and the CLI, generating and persisting one (mode
/// 0600, not the shared ~/.erlang.cookie) on first run.
pub fn load_or_create_cookie() -> Result(String, DistributionError) {
  case simplifile.read(cookie_file) {
    Ok(existing) -> Ok(string.trim(existing))
    Error(simplifile.Enoent) -> create_cookie()
    Error(reason) -> Error(CookieFileError(reason))
  }
}

fn create_cookie() -> Result(String, DistributionError) {
  use _ <- result.try(
    write_cookie_if_absent(cookie_file, random_cookie())
    |> result.map_error(CookieWriteError),
  )
  // Another process may have won the race to create the file first, with a
  // different cookie than the one generated above — read back whatever
  // ended up on disk so every process agrees on the same cookie.
  simplifile.read(cookie_file)
  |> result.map(string.trim)
  |> result.map_error(CookieFileError)
}

/// Turns the current node into a distributed one, so it can be reached (as
/// the daemon) or reach another node (as the CLI).
pub fn ensure_started(
  short_name: String,
  cookie: String,
) -> Result(Nil, DistributionError) {
  ensure_started_ffi(short_name, cookie) |> result.map_error(StartFailed)
}

/// Runs on the daemon node, invoked by the CLI over RPC — never called
/// directly from Gleam code in this package.
pub fn query_status() -> StatusReport {
  let index = process.named_subject(torrent_index_name())
  let status = process.call(index, 5000, torrent_index.Status)
  StatusReport(
    torrent_count: status.torrent_count,
    piece_sizes: status.piece_sizes,
    resync_success_count: status.resync_success_count,
    resync_failure_count: status.resync_failure_count,
  )
}

pub fn query_remote_status(
  daemon_short_name: String,
) -> Result(StatusReport, DistributionError) {
  let node_name = daemon_short_name <> "@" <> hostname()
  case ping(node_name) {
    False -> Error(DaemonUnreachable)
    True -> rpc_query_status(node_name, 5000) |> result.map_error(RpcFailed)
  }
}

@external(erlang, "arr_sync_distribution_ffi", "fixed_name")
fn fixed_name(prefix: String) -> process.Name(msg)

@external(erlang, "arr_sync_distribution_ffi", "ensure_started")
fn ensure_started_ffi(short_name: String, cookie: String) -> Result(Nil, String)

@external(erlang, "arr_sync_distribution_ffi", "hostname")
pub fn hostname() -> String

@external(erlang, "arr_sync_distribution_ffi", "node_name")
pub fn node_name() -> String

@external(erlang, "arr_sync_distribution_ffi", "ping")
fn ping(node_name: String) -> Bool

@external(erlang, "arr_sync_distribution_ffi", "write_cookie_if_absent")
fn write_cookie_if_absent(path: String, content: String) -> Result(Nil, String)

@external(erlang, "arr_sync_distribution_ffi", "random_cookie")
fn random_cookie() -> String

@external(erlang, "arr_sync_distribution_ffi", "os_pid")
pub fn os_pid() -> String

@external(erlang, "arr_sync_distribution_ffi", "rpc_query_status")
fn rpc_query_status(
  node_name: String,
  timeout_ms: Int,
) -> Result(StatusReport, String)
