import argv
import arr_sync/client/qbittorrent
import arr_sync/config
import arr_sync/distribution
import arr_sync/logging
import arr_sync/matcher/torrent_index
import arr_sync/syncer
import arr_sync/watcher/fs_watcher
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/string
import simplifile

/// Short node name the daemon registers under when distribution starts.
/// The CLI's `status` command dials this same name to reach it.
const daemon_node_short_name = "arr_sync"

pub fn main() {
  case argv.load().arguments {
    ["start"] -> start("arr-sync.toml")
    ["start", "--config", path] -> start(path)
    ["match", path] -> match_file(path)
    ["status"] -> show_status()
    ["list"] -> list_torrents()
    ["resync", torrent_hash] -> force_resync(torrent_hash)
    _ ->
      logging.log(
        logging.Error,
        "usage: arr_sync <start|match|status|list|resync> [args]",
      )
  }
}

fn start(config_path: String) -> Nil {
  case config.load(config_path) {
    Error(_reason) ->
      logging.log(logging.Error, "failed to load config from " <> config_path)
    Ok(loaded_config) -> {
      let credentials =
        qbittorrent.Credentials(
          url: loaded_config.qbittorrent.url,
          username: loaded_config.qbittorrent.username,
          password: loaded_config.qbittorrent.password,
        )

      start_distribution()

      // Created once at startup and closed over by the children below, so
      // syncer can look up torrent_index's and fs_watcher's Subjects
      // without a runtime handshake. torrent_index's name is fixed (not
      // process.new_name's random suffix) so `arr-sync status`, running in
      // a separate OS process, can reconstruct the same Name and reach it
      // over distributed Erlang — see arr_sync/distribution.
      let index_name = distribution.torrent_index_name()
      let watcher_name = process.new_name("fs_watcher")

      let assert Ok(_supervisor) =
        supervisor.new(supervisor.OneForOne)
        |> supervisor.add(
          supervision.worker(fn() {
            fs_watcher.start(loaded_config.watch.paths, watcher_name)
          }),
        )
        |> supervisor.add(
          supervision.worker(fn() {
            torrent_index.start(
              credentials,
              loaded_config.sync.recheck_delay_seconds,
              loaded_config.path_mappings,
              index_name,
            )
          })
          |> supervision.timeout(ms: 20_000),
        )
        |> supervisor.add(
          supervision.worker(fn() {
            syncer.start(loaded_config, index_name, watcher_name)
          }),
        )
        |> supervisor.restart_tolerance(intensity: 3, period: 60)
        |> supervisor.start

      logging.log(logging.Info, "arr-sync started, watching " <> config_path)
      process.sleep_forever()
    }
  }
}

/// Distribution failing to start (e.g. epmd unavailable in a locked-down
/// container) is not fatal — the daemon still runs, just unreachable by
/// `arr-sync status`.
fn start_distribution() -> Nil {
  case distribution.load_or_create_cookie() {
    Error(reason) ->
      logging.log(
        logging.Warning,
        "arr-sync status will not work: " <> string.inspect(reason),
      )
    Ok(cookie) ->
      case distribution.ensure_started(daemon_node_short_name, cookie) {
        Ok(Nil) ->
          logging.log(
            logging.Info,
            "reachable for `arr-sync status` as " <> distribution.node_name(),
          )
        Error(reason) ->
          logging.log(
            logging.Warning,
            "arr-sync status will not work: " <> string.inspect(reason),
          )
      }
  }
}

fn show_status() -> Nil {
  case distribution.load_or_create_cookie() {
    Error(reason) ->
      logging.log(
        logging.Error,
        "cannot access " <> ".arr-sync-cookie: " <> string.inspect(reason),
      )
    Ok(cookie) -> {
      let cli_short_name = "arr_sync_cli_" <> distribution.os_pid()
      case distribution.ensure_started(cli_short_name, cookie) {
        Error(reason) ->
          logging.log(
            logging.Error,
            "could not start distributed Erlang: " <> string.inspect(reason),
          )
        Ok(Nil) ->
          case distribution.query_remote_status(daemon_node_short_name) {
            Ok(status) ->
              logging.log(
                logging.Info,
                "daemon reachable — "
                  <> int.to_string(status.torrent_count)
                  <> " torrents indexed, piece sizes seen: "
                  <> string.inspect(status.piece_sizes)
                  <> ", resyncs: "
                  <> int.to_string(status.resync_success_count)
                  <> " ok / "
                  <> int.to_string(status.resync_failure_count)
                  <> " failed",
              )
            Error(distribution.DaemonUnreachable) ->
              logging.log(
                logging.Error,
                "daemon not reachable — is `arr-sync start` running?",
              )
            Error(reason) ->
              logging.log(
                logging.Error,
                "status query failed: " <> string.inspect(reason),
              )
          }
      }
    }
  }
}

/// Loads arr-sync.toml, logs into qBittorrent, and hands the session and
/// config to `action` — shared by every CLI subcommand that just needs
/// one-off access to qBittorrent, without the daemon's supervision tree.
fn with_session(action: fn(qbittorrent.Session, config.Config) -> Nil) -> Nil {
  case config.load("arr-sync.toml") {
    Error(_reason) ->
      logging.log(logging.Error, "failed to load config from arr-sync.toml")
    Ok(loaded_config) -> {
      let credentials =
        qbittorrent.Credentials(
          url: loaded_config.qbittorrent.url,
          username: loaded_config.qbittorrent.username,
          password: loaded_config.qbittorrent.password,
        )
      case qbittorrent.login(credentials) {
        Error(_reason) -> logging.log(logging.Error, "qBittorrent login failed")
        Ok(session) -> action(session, loaded_config)
      }
    }
  }
}

fn match_file(path: String) -> Nil {
  use session, loaded_config <- with_session()
  let index = torrent_index.fetch_index(session, loaded_config.path_mappings)
  report_match(path, index)
}

fn list_torrents() -> Nil {
  use session, loaded_config <- with_session()
  let index = torrent_index.fetch_index(session, loaded_config.path_mappings)
  case dict.values(index.torrents) {
    [] -> logging.log(logging.Info, "no torrents indexed")
    entries ->
      list.each(entries, fn(entry) {
        logging.log(logging.Info, entry.hash <> "  " <> entry.name)
      })
  }
}

fn force_resync(torrent_hash: String) -> Nil {
  use session, _loaded_config <- with_session()
  case qbittorrent.recheck(session, torrent_hash) {
    Ok(Nil) ->
      logging.log(logging.Info, "recheck triggered for " <> torrent_hash)
    Error(reason) ->
      logging.log(
        logging.Error,
        "recheck failed for " <> torrent_hash <> ": " <> string.inspect(reason),
      )
  }
}

fn report_match(path: String, index: torrent_index.Index) -> Nil {
  let probes = torrent_index.probes(index)
  let lookup = fn(hash) { torrent_index.find_match(index, hash) }
  case torrent_index.find_first_match(path, probes, lookup) {
    Ok(torrent_index.Matched(torrent_hash, _piece_hash)) ->
      logging.log(logging.Info, path <> " matches torrent " <> torrent_hash)
    Ok(torrent_index.Ambiguous(_piece_hash, candidates)) ->
      logging.log(
        logging.Warning,
        path <> " matches multiple torrents: " <> string.join(candidates, ", "),
      )
    Ok(torrent_index.NoMatch) | Error(Nil) -> report_match_by_size(path, index)
  }
}

// Same by-size fallback as the daemon's syncer, for files that don't start
// on a piece boundary — see torrent_index.SizeCandidate.
fn report_match_by_size(path: String, index: torrent_index.Index) -> Nil {
  let verified = case simplifile.file_info(path) {
    Error(_) -> []
    Ok(info) ->
      torrent_index.verify_size_candidates(
        path,
        torrent_index.size_candidates(index, info.size),
      )
  }
  case verified {
    [] -> logging.log(logging.Info, "no torrent matches " <> path)
    candidates ->
      list.each(candidates, fn(candidate) {
        logging.log(
          logging.Info,
          path
            <> " matches torrent "
            <> candidate.torrent_hash
            <> " (by size + interior piece)",
        )
      })
  }
}
