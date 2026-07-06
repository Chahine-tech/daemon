import arr_sync/client/radarr
import arr_sync/client/sonarr
import arr_sync/config.{type Config}
import arr_sync/logging
import arr_sync/matcher/torrent_index
import arr_sync/watcher/fs_watcher.{type FsEvent}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/string
import simplifile

pub type Message {
  HandleFsEvent(FsEvent)
  HandleResyncOutcome(torrent_index.ResyncOutcome)
  Shutdown
}

type SyncerState {
  SyncerState(
    config: Config,
    index: Subject(torrent_index.Message),
    resync_outcomes: Subject(torrent_index.ResyncOutcome),
  )
}

pub fn start(
  config: Config,
  index_name: process.Name(torrent_index.Message),
  watcher_name: process.Name(fs_watcher.Message),
) -> actor.StartResult(Subject(Message)) {
  actor.new_with_initialiser(1000, fn(subject) {
    let index = process.named_subject(index_name)
    let watcher = process.named_subject(watcher_name)

    // fs_watcher only knows Subject(FsEvent), not our own Message type, so
    // we hand it a dedicated subject and fold its events into our own
    // mailbox pre-wrapped as HandleFsEvent via select_map. Same pattern for
    // resync outcomes, which torrent_index sends back asynchronously.
    let fs_event_subject = process.new_subject()
    process.send(watcher, fs_watcher.Subscribe(fs_event_subject))
    let resync_outcomes = process.new_subject()

    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_map(fs_event_subject, HandleFsEvent)
      |> process.select_map(resync_outcomes, HandleResyncOutcome)

    actor.initialised(SyncerState(config:, index:, resync_outcomes:))
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_message)
  |> actor.start
}

fn handle_message(
  state: SyncerState,
  message: Message,
) -> actor.Next(SyncerState, Message) {
  case message {
    HandleFsEvent(fs_event) -> {
      handle_fs_event(state, fs_event)
      actor.continue(state)
    }
    HandleResyncOutcome(outcome) -> {
      handle_resync_outcome(state, outcome)
      actor.continue(state)
    }
    Shutdown -> actor.stop()
  }
}

fn handle_fs_event(state: SyncerState, fs_event: FsEvent) -> Nil {
  case fs_event {
    fs_watcher.Deleted(_) -> Nil
    fs_watcher.Created(path) -> resync_if_large_enough(state, path)
  }
}

/// Sidecar files (subtitles, .nfo, thumbnails) fire the same Created event
/// as the media file itself, but are never worth piece-hashing — this skips
/// them cheaply with a single stat call before any hashing happens.
fn resync_if_large_enough(state: SyncerState, path: String) -> Nil {
  let min_size_bytes = state.config.sync.min_file_size_mb * 1_048_576
  case simplifile.file_info(path) {
    Ok(info) if info.size >= min_size_bytes -> resync(state, path, info.size)
    _ -> Nil
  }
}

fn resync(state: SyncerState, path: String, size: Int) -> Nil {
  let probes = process.call(state.index, 5000, torrent_index.Probes)
  let lookup = fn(hash) {
    process.call(state.index, 5000, torrent_index.Lookup(hash, _))
  }

  case torrent_index.find_first_match(path, probes, lookup) {
    Ok(torrent_index.Matched(torrent_hash, piece_hash)) -> {
      // Fire-and-forget: a resync takes seconds (recheck delay, retry
      // backoffs), and the next fs event can't wait on it — the outcome
      // comes back as a HandleResyncOutcome message instead.
      process.send(
        state.index,
        torrent_index.Resync(
          torrent_hash,
          piece_hash,
          path,
          state.resync_outcomes,
        ),
      )
      logging.log(
        logging.Info,
        path <> " matches torrent " <> torrent_hash <> ", resyncing",
      )
    }
    // Several torrents sharing a piece hash means the same content seeded
    // more than once (cross-seeding across trackers) — every candidate
    // needs the resync, not none of them. do_resync's size check guards
    // the pathological case of torrents sharing only their first piece.
    Ok(torrent_index.Ambiguous(piece_hash, candidates)) -> {
      logging.log(
        logging.Info,
        path
          <> " matches multiple torrents (cross-seed), resyncing all: "
          <> string.join(candidates, ", "),
      )
      list.each(candidates, fn(torrent_hash) {
        process.send(
          state.index,
          torrent_index.Resync(
            torrent_hash,
            piece_hash,
            path,
            state.resync_outcomes,
          ),
        )
      })
    }
    Ok(torrent_index.NoMatch) | Error(Nil) -> resync_by_size(state, path, size)
  }
}

/// First-piece matching misses files that don't start on a piece boundary
/// (interior files of a v1 multi-file torrent without pad files — verified
/// live, see torrent_index.SizeCandidate). Fallback: candidates with the
/// same exact size, verified by hashing the file's first fully-contained
/// piece at its known in-file offset.
fn resync_by_size(state: SyncerState, path: String, size: Int) -> Nil {
  let candidates =
    process.call(state.index, 5000, torrent_index.SizeCandidates(size, _))
  case torrent_index.verify_size_candidates(path, candidates) {
    [] -> logging.log(logging.Info, "no torrent matches " <> path)
    verified -> {
      logging.log(
        logging.Info,
        path
          <> " matches by size + interior piece, resyncing: "
          <> string.join(
          list.map(verified, fn(candidate) { candidate.torrent_hash }),
          ", ",
        ),
      )
      list.each(verified, fn(candidate) {
        process.send(
          state.index,
          torrent_index.Resync(
            candidate.torrent_hash,
            candidate.piece_hash,
            path,
            state.resync_outcomes,
          ),
        )
      })
    }
  }
}

fn handle_resync_outcome(
  state: SyncerState,
  outcome: torrent_index.ResyncOutcome,
) -> Nil {
  case outcome.result {
    Ok(Nil) -> {
      logging.log(
        logging.Info,
        outcome.new_absolute_path
          <> " resynced with torrent "
          <> outcome.torrent_hash,
      )
      notify_arr_stack(state.config)
    }
    Error(reason) ->
      logging.log(
        logging.Error,
        "failed to resync "
          <> outcome.new_absolute_path
          <> " with torrent "
          <> outcome.torrent_hash
          <> ": "
          <> string.inspect(reason),
      )
  }
}

fn notify_arr_stack(config: Config) -> Nil {
  case config.sonarr {
    None -> Nil
    Some(arr_config) -> {
      let credentials =
        sonarr.Credentials(url: arr_config.url, api_key: arr_config.api_key)
      case sonarr.notify_file_synced(credentials) {
        Ok(Nil) -> logging.log(logging.Info, "sonarr rescan requested")
        Error(reason) ->
          logging.log(
            logging.Warning,
            "sonarr notification failed: " <> string.inspect(reason),
          )
      }
    }
  }

  case config.radarr {
    None -> Nil
    Some(arr_config) -> {
      let credentials =
        radarr.Credentials(url: arr_config.url, api_key: arr_config.api_key)
      case radarr.notify_file_synced(credentials) {
        Ok(Nil) -> logging.log(logging.Info, "radarr rescan requested")
        Error(reason) ->
          logging.log(
            logging.Warning,
            "radarr notification failed: " <> string.inspect(reason),
          )
      }
    }
  }
}
