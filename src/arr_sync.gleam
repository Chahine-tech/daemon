import argv
import client/qbittorrent
import config/config
import gleam/erlang/process
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/string
import logging
import matcher/piece_hasher
import matcher/torrent_index
import syncer
import watcher/fs_watcher

pub fn main() {
  case argv.load().arguments {
    ["start"] -> start("arr-sync.toml")
    ["start", "--config", path] -> start(path)
    ["match", path] -> match_file(path)
    ["status"] ->
      todo as "read daemon state, e.g. via a registered process name"
    ["list"] -> todo as "ask torrent_index for its indexed entries"
    ["resync", _torrent_hash] ->
      todo as "force a resync on a single torrent hash"
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

      // Created once at startup and closed over by both children below, so
      // syncer can look up torrent_index's Subject without a runtime handshake.
      let index_name = process.new_name("torrent_index")

      let assert Ok(_supervisor) =
        supervisor.new(supervisor.OneForOne)
        |> supervisor.add(
          supervision.worker(fn() {
            fs_watcher.start(loaded_config.watch.paths)
          }),
        )
        |> supervisor.add(
          supervision.worker(fn() {
            torrent_index.start(credentials, index_name)
          })
          |> supervision.timeout(ms: 10_000),
        )
        |> supervisor.add(
          supervision.worker(fn() { syncer.start(loaded_config, index_name) }),
        )
        |> supervisor.restart_tolerance(intensity: 3, period: 60)
        |> supervisor.start

      logging.log(logging.Info, "arr-sync started, watching " <> config_path)
      process.sleep_forever()
    }
  }
}

fn match_file(path: String) -> Nil {
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
        Ok(session) -> {
          let index = torrent_index.fetch_index(session)
          report_match(path, index)
        }
      }
    }
  }
}

fn report_match(path: String, index: torrent_index.Index) -> Nil {
  case find_first_match(path, torrent_index.piece_sizes(index), index) {
    Ok(torrent_index.Matched(torrent_hash)) ->
      logging.log(logging.Info, path <> " matches torrent " <> torrent_hash)
    Ok(torrent_index.Ambiguous(candidates)) ->
      logging.log(
        logging.Warning,
        path <> " matches multiple torrents: " <> string.join(candidates, ", "),
      )
    Ok(torrent_index.NoMatch) | Error(Nil) ->
      logging.log(logging.Info, "no torrent matches " <> path)
  }
}

/// Tries each distinct piece size present in the index (a candidate file's
/// piece hash only lines up with a torrent using the same piece size),
/// stopping at the first size that produces a match.
fn find_first_match(
  path: String,
  piece_sizes: List(Int),
  index: torrent_index.Index,
) -> Result(torrent_index.MatchResult, Nil) {
  case piece_sizes {
    [] -> Error(Nil)
    [piece_size, ..rest] ->
      case
        piece_hasher.hash_first_pieces(
          path,
          piece_hasher.PieceSize(piece_size),
          1,
        )
      {
        Ok([piece_hash, ..]) ->
          case torrent_index.find_match(index, piece_hash) {
            torrent_index.NoMatch -> find_first_match(path, rest, index)
            result -> Ok(result)
          }
        _ -> find_first_match(path, rest, index)
      }
  }
}
