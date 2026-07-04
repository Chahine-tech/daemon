import arr_sync/client/qbittorrent.{type Session}
import arr_sync/logging
import arr_sync/matcher/piece_hasher
import filepath
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string

pub type TorrentFile {
  TorrentFile(
    name: String,
    size: Int,
    progress: Float,
    piece_range: #(Int, Int),
  )
}

pub type TorrentEntry {
  TorrentEntry(
    hash: String,
    name: String,
    save_path: String,
    files: List(TorrentFile),
    piece_size: Int,
    piece_hashes: List(String),
  )
}

pub type MatchResult {
  Matched(torrent_hash: String, piece_hash: String)
  NoMatch
  Ambiguous(candidates: List(String))
}

pub type ResyncError {
  UnknownMatch(torrent_hash: String, piece_hash: String)
  QbittorrentFailure(qbittorrent.QbittorrentError)
}

pub type IndexStatus {
  IndexStatus(torrent_count: Int, piece_sizes: List(Int))
}

pub type Message {
  Refresh
  Lookup(piece_hash: String, reply_to: Subject(MatchResult))
  PieceSizes(reply_to: Subject(List(Int)))
  Status(reply_to: Subject(IndexStatus))
  Resync(
    torrent_hash: String,
    piece_hash: String,
    new_absolute_path: String,
    reply_to: Subject(Result(Nil, ResyncError)),
  )
  Shutdown
}

pub type Index {
  Index(
    torrents: Dict(String, TorrentEntry),
    by_piece_hash: Dict(String, List(String)),
  )
}

type IndexState {
  IndexState(
    credentials: qbittorrent.Credentials,
    session: Session,
    index: Index,
    self: Subject(Message),
    recheck_delay_seconds: Int,
  )
}

/// How often the index is rebuilt from qBittorrent on its own, so torrents
/// added after the daemon started eventually become matchable — nothing
/// else ever sends Refresh.
const refresh_interval_ms = 300_000

/// Retries for a transient qBittorrent failure (connection lost) or an
/// expired session (re-authenticates first) before giving up.
const max_retries = 3

pub fn start(
  credentials: qbittorrent.Credentials,
  recheck_delay_seconds: Int,
  name: process.Name(Message),
) -> actor.StartResult(Subject(Message)) {
  actor.new_with_initialiser(15_000, fn(subject) {
    case qbittorrent.login(credentials) {
      Ok(session) -> {
        // Fetch the index synchronously at startup — the first scheduled
        // Refresh is 5 minutes away, so without this the actor would sit
        // empty (and match nothing) until then.
        let index = fetch_index_result(session) |> result.unwrap(empty_index())
        process.send_after(subject, refresh_interval_ms, Refresh)
        actor.initialised(IndexState(
          credentials:,
          session:,
          index:,
          self: subject,
          recheck_delay_seconds:,
        ))
        |> actor.returning(subject)
        |> Ok
      }
      Error(_reason) -> Error("qBittorrent login failed")
    }
  })
  |> actor.on_message(handle_message)
  |> actor.named(name)
  |> actor.start
}

fn empty_index() -> Index {
  Index(torrents: dict.new(), by_piece_hash: dict.new())
}

fn handle_message(
  state: IndexState,
  message: Message,
) -> actor.Next(IndexState, Message) {
  case message {
    Refresh -> {
      let #(result, state) = with_retry(state, fetch_index_result)
      let index = case result {
        Ok(new_index) -> new_index
        Error(reason) -> {
          // Keep the last known-good index rather than wiping it — a
          // transient qBittorrent outage shouldn't erase everything that
          // was already matchable.
          logging.log(
            logging.Warning,
            "refresh failed, keeping previous index: " <> string.inspect(reason),
          )
          state.index
        }
      }
      process.send_after(state.self, refresh_interval_ms, Refresh)
      actor.continue(IndexState(..state, index:))
    }
    Lookup(piece_hash, reply_to) -> {
      process.send(reply_to, find_match(state.index, piece_hash))
      actor.continue(state)
    }
    PieceSizes(reply_to) -> {
      process.send(reply_to, piece_sizes(state.index))
      actor.continue(state)
    }
    Status(reply_to) -> {
      process.send(
        reply_to,
        IndexStatus(
          torrent_count: dict.size(state.index.torrents),
          piece_sizes: piece_sizes(state.index),
        ),
      )
      actor.continue(state)
    }
    Resync(torrent_hash, piece_hash, new_absolute_path, reply_to) -> {
      let #(result, state) =
        resync_with_retry(
          state,
          torrent_hash,
          piece_hash,
          new_absolute_path,
          state.recheck_delay_seconds,
          1,
        )
      process.send(reply_to, result)
      actor.continue(state)
    }
    Shutdown -> actor.stop()
  }
}

/// Runs `action` against the current session, transparently re-authenticating
/// on a session-expired response and retrying with backoff on a connection
/// failure — up to `max_retries` times — instead of surfacing the first
/// failure straight to the caller. Returns the possibly-updated state
/// (a fresh session after re-authenticating) alongside the result.
fn with_retry(
  state: IndexState,
  action: fn(Session) -> Result(a, qbittorrent.QbittorrentError),
) -> #(Result(a, qbittorrent.QbittorrentError), IndexState) {
  attempt(state, action, 1)
}

fn attempt(
  state: IndexState,
  action: fn(Session) -> Result(a, qbittorrent.QbittorrentError),
  attempt_number: Int,
) -> #(Result(a, qbittorrent.QbittorrentError), IndexState) {
  case action(state.session) {
    Ok(value) -> #(Ok(value), state)
    Error(qbittorrent.UnexpectedStatus(403, _))
      if attempt_number <= max_retries
    -> {
      logging.log(
        logging.Warning,
        "qBittorrent session expired, re-authenticating (attempt "
          <> int.to_string(attempt_number)
          <> ")",
      )
      case qbittorrent.login(state.credentials) {
        Ok(new_session) ->
          attempt(
            IndexState(..state, session: new_session),
            action,
            attempt_number + 1,
          )
        Error(login_error) -> #(Error(login_error), state)
      }
    }
    Error(reason) if attempt_number <= max_retries -> {
      case is_connection_error(reason) {
        False -> #(Error(reason), state)
        True -> {
          let delay_ms = backoff_delay_ms(attempt_number)
          logging.log(
            logging.Warning,
            "qBittorrent unreachable, retrying in "
              <> int.to_string(delay_ms)
              <> "ms (attempt "
              <> int.to_string(attempt_number)
              <> "): "
              <> string.inspect(reason),
          )
          process.sleep(delay_ms)
          attempt(state, action, attempt_number + 1)
        }
      }
    }
    Error(reason) -> #(Error(reason), state)
  }
}

/// RequestFailed is gleam_httpc's own typed connection errors (refused,
/// timed out, TLS failure). ConnectionLost is the fallback for httpc-level
/// errors gleam_httpc doesn't normalise into a Result at all — see
/// QbittorrentError's ConnectionLost doc comment. Both are worth retrying;
/// a 403 (session expired) is handled separately, by re-authenticating.
fn is_connection_error(reason: qbittorrent.QbittorrentError) -> Bool {
  case reason {
    qbittorrent.RequestFailed(_) -> True
    qbittorrent.ConnectionLost(_) -> True
    _ -> False
  }
}

fn backoff_delay_ms(attempt_number: Int) -> Int {
  // 1s, 2s, 4s
  1000 * int.bitwise_shift_left(1, attempt_number - 1)
}

pub fn fetch_index(session: Session) -> Index {
  fetch_index_result(session) |> result.unwrap(empty_index())
}

fn fetch_index_result(
  session: Session,
) -> Result(Index, qbittorrent.QbittorrentError) {
  use summaries <- result.try(qbittorrent.list_torrents(session))
  summaries
  |> list.filter_map(fn(summary) { fetch_entry(session, summary) })
  |> build_index
  |> Ok
}

fn fetch_entry(
  session: Session,
  summary: qbittorrent.TorrentSummary,
) -> Result(TorrentEntry, Nil) {
  case
    qbittorrent.torrent_files(session, summary.hash),
    qbittorrent.piece_hashes(session, summary.hash),
    qbittorrent.properties(session, summary.hash)
  {
    Ok(files), Ok(piece_hashes), Ok(properties) ->
      Ok(TorrentEntry(
        hash: summary.hash,
        name: summary.name,
        save_path: summary.save_path,
        files: list.map(files, fn(file) {
          TorrentFile(
            name: file.name,
            size: file.size,
            progress: file.progress,
            piece_range: file.piece_range,
          )
        }),
        piece_size: properties.piece_size,
        piece_hashes:,
      ))
    _, _, _ -> {
      logging.log(
        logging.Warning,
        "skipping torrent "
          <> summary.hash
          <> ": could not fetch its files/piece hashes/properties",
      )
      Error(Nil)
    }
  }
}

/// The distinct piece sizes present in the index. In practice a small,
/// stable set (BitTorrent clients pick from a handful of standard sizes),
/// so this drives how many times a candidate file needs re-hashing.
pub fn piece_sizes(index: Index) -> List(Int) {
  index.torrents
  |> dict.values
  |> list.map(fn(entry) { entry.piece_size })
  |> list.unique
}

pub fn build_index(entries: List(TorrentEntry)) -> Index {
  let torrents =
    entries
    |> list.map(fn(entry) { #(entry.hash, entry) })
    |> dict.from_list

  // A torrent can repeat the same piece hash internally (e.g. a long run of
  // identical bytes hashes identically) — dedupe per torrent_hash so that
  // doesn't get mistaken for cross-torrent ambiguity.
  let by_piece_hash =
    list.fold(entries, dict.new(), fn(index, entry) {
      list.fold(entry.piece_hashes, index, fn(index, piece_hash) {
        dict.upsert(index, piece_hash, fn(existing) {
          case existing {
            Some(torrent_hashes) ->
              case list.contains(torrent_hashes, entry.hash) {
                True -> torrent_hashes
                False -> [entry.hash, ..torrent_hashes]
              }
            None -> [entry.hash]
          }
        })
      })
    })

  Index(torrents:, by_piece_hash:)
}

pub fn find_match(index: Index, piece_hash: String) -> MatchResult {
  case dict.get(index.by_piece_hash, piece_hash) {
    Error(Nil) -> NoMatch
    Ok([]) -> NoMatch
    Ok([torrent_hash]) -> Matched(torrent_hash:, piece_hash:)
    Ok(candidates) -> Ambiguous(candidates:)
  }
}

/// Resolves a matched piece hash down to the specific file inside the
/// torrent it belongs to, using the [start, end] piece_range qBittorrent
/// reports per file (torrents/files) — no cumulative offset math needed.
pub fn resolve(
  index: Index,
  torrent_hash: String,
  piece_hash: String,
) -> Result(#(TorrentEntry, TorrentFile), Nil) {
  use entry <- result.try(
    dict.get(index.torrents, torrent_hash) |> result.replace_error(Nil),
  )
  use piece_index <- result.try(piece_index_of(entry.piece_hashes, piece_hash))
  use file <- result.try(
    list.find(entry.files, fn(file) {
      let #(start, end) = file.piece_range
      piece_index >= start && piece_index <= end
    }),
  )
  Ok(#(entry, file))
}

fn piece_index_of(
  piece_hashes: List(String),
  piece_hash: String,
) -> Result(Int, Nil) {
  piece_hashes
  |> list.index_map(fn(hash, index) { #(hash, index) })
  |> list.find_map(fn(pair) {
    case pair.0 == piece_hash {
      True -> Ok(pair.1)
      False -> Error(Nil)
    }
  })
}

/// Renames/moves the resolved file inside qBittorrent to match where it now
/// actually lives on disk, then forces a recheck.
///
/// Verified live this needs to branch in two genuinely different ways:
/// - If the new path is still somewhere under the torrent's current
///   save_path (even in a different subdirectory — file.name for a
///   multi-file torrent already carries its own subdirectory prefix, e.g.
///   "ShowPack/episode.bin"), renameFile alone is correct. Comparing
///   directory_name(new_path) to save_path directly is wrong here: it's
///   almost always a deeper path than save_path once file.name has a
///   subdirectory prefix, which caused a spurious setLocation that doubled
///   the path into ".../ShowPack/ShowPack/...".
/// - Only when the new path leaves save_path's tree entirely (e.g. moved
///   from downloads/complete into the media library) does the torrent's
///   save_path itself need to move.
fn do_resync(
  session: Session,
  index: Index,
  torrent_hash: String,
  piece_hash: String,
  new_absolute_path: String,
  recheck_delay_seconds: Int,
) -> Result(Nil, ResyncError) {
  use #(entry, file) <- result.try(
    resolve(index, torrent_hash, piece_hash)
    |> result.replace_error(UnknownMatch(torrent_hash:, piece_hash:)),
  )

  use new_relative_path <- result.try(
    case relative_to(entry.save_path, new_absolute_path) {
      Ok(relative_path) -> Ok(relative_path)
      Error(Nil) -> {
        // Left save_path's tree entirely: move save_path to the new parent
        // directory, then rename with just the filename — we can't infer
        // intended subdirectory structure from a path outside the torrent's
        // own tree.
        let new_dir = filepath.directory_name(new_absolute_path)
        use _ <- result.try(
          qbittorrent.set_location(session, torrent_hash, new_dir)
          |> result.map_error(QbittorrentFailure),
        )
        Ok(filepath.base_name(new_absolute_path))
      }
    },
  )

  use _ <- result.try(
    qbittorrent.rename_file(session, torrent_hash, file.name, new_relative_path)
    |> result.map_error(QbittorrentFailure),
  )

  // Give qBittorrent a moment to settle the rename on its side before
  // forcing a recheck — configurable since how long that takes depends on
  // torrent size and disk speed.
  process.sleep(recheck_delay_seconds * 1000)

  qbittorrent.recheck(session, torrent_hash)
  |> result.map_error(QbittorrentFailure)
}

fn resync_with_retry(
  state: IndexState,
  torrent_hash: String,
  piece_hash: String,
  new_absolute_path: String,
  recheck_delay_seconds: Int,
  attempt_number: Int,
) -> #(Result(Nil, ResyncError), IndexState) {
  case
    do_resync(
      state.session,
      state.index,
      torrent_hash,
      piece_hash,
      new_absolute_path,
      recheck_delay_seconds,
    )
  {
    Error(QbittorrentFailure(qbittorrent.UnexpectedStatus(403, _)))
      if attempt_number <= max_retries
    -> {
      logging.log(
        logging.Warning,
        "qBittorrent session expired during resync, re-authenticating (attempt "
          <> int.to_string(attempt_number)
          <> ")",
      )
      case qbittorrent.login(state.credentials) {
        Ok(new_session) ->
          resync_with_retry(
            IndexState(..state, session: new_session),
            torrent_hash,
            piece_hash,
            new_absolute_path,
            recheck_delay_seconds,
            attempt_number + 1,
          )
        Error(login_error) -> #(Error(QbittorrentFailure(login_error)), state)
      }
    }
    Error(QbittorrentFailure(reason)) as error_result
      if attempt_number <= max_retries
    -> {
      case is_connection_error(reason) {
        False -> #(error_result, state)
        True -> {
          let delay_ms = backoff_delay_ms(attempt_number)
          logging.log(
            logging.Warning,
            "qBittorrent unreachable during resync, retrying in "
              <> int.to_string(delay_ms)
              <> "ms (attempt "
              <> int.to_string(attempt_number)
              <> "): "
              <> string.inspect(reason),
          )
          process.sleep(delay_ms)
          resync_with_retry(
            state,
            torrent_hash,
            piece_hash,
            new_absolute_path,
            recheck_delay_seconds,
            attempt_number + 1,
          )
        }
      }
    }
    result -> #(result, state)
  }
}

@internal
pub fn relative_to(base: String, path: String) -> Result(String, Nil) {
  case string.starts_with(path, base <> "/") {
    True -> Ok(string.drop_start(path, string.length(base) + 1))
    False -> Error(Nil)
  }
}

/// Tries each candidate piece size against `path` (a file's piece hash only
/// lines up with a torrent using the same piece size), stopping at the
/// first one that produces a match. `lookup` is injected so this works both
/// synchronously against an already-fetched `Index` (the CLI) and via
/// actor round-trips against a running torrent_index (the daemon).
pub fn find_first_match(
  path: String,
  piece_sizes: List(Int),
  lookup: fn(String) -> MatchResult,
) -> Result(MatchResult, Nil) {
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
          case lookup(piece_hash) {
            NoMatch -> find_first_match(path, rest, lookup)
            result -> Ok(result)
          }
        _ -> find_first_match(path, rest, lookup)
      }
  }
}
