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
import simplifile

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
  Ambiguous(piece_hash: String, candidates: List(String))
}

pub type ResyncError {
  UnknownMatch(torrent_hash: String, piece_hash: String)
  // The file on disk isn't the size this torrent expects — matching only
  // hashes a file's first piece, so this catches the (pathological but
  // seeding-breaking) case of two torrents sharing their first piece and
  // nothing else: renaming the wrong one would drop it to missing pieces
  // on recheck.
  SizeMismatch(torrent_hash: String, expected: Int, actual: Int)
  QbittorrentFailure(qbittorrent.QbittorrentError)
}

pub type IndexStatus {
  IndexStatus(
    torrent_count: Int,
    piece_sizes: List(Int),
    resync_success_count: Int,
    resync_failure_count: Int,
  )
}

/// What a resync attempt ended up doing, sent asynchronously to whoever
/// requested it — carries the torrent and path so the receiver can log and
/// react without having blocked waiting for the answer.
pub type ResyncOutcome {
  ResyncOutcome(
    torrent_hash: String,
    new_absolute_path: String,
    result: Result(Nil, ResyncError),
  )
}

pub type Message {
  Refresh
  // Sent back by the worker process Refresh spawns — never by other actors.
  IndexFetched(
    result: Result(Index, qbittorrent.QbittorrentError),
    session: Session,
  )
  Lookup(piece_hash: String, reply_to: Subject(MatchResult))
  SizeCandidates(size: Int, reply_to: Subject(List(SizeCandidate)))
  PieceSizes(reply_to: Subject(List(Int)))
  Status(reply_to: Subject(IndexStatus))
  Resync(
    torrent_hash: String,
    piece_hash: String,
    new_absolute_path: String,
    reply_to: Subject(ResyncOutcome),
  )
  // Sent back by the worker process Resync spawns — never by other actors.
  ResyncFinished(
    outcome: ResyncOutcome,
    session: Session,
    reply_to: Subject(ResyncOutcome),
  )
  Shutdown
}

/// Fallback probe for a file that doesn't start on a piece boundary. In a
/// v1 multi-file torrent without pad files, only the first file is
/// piece-aligned — hashing an interior file's first bytes never matches any
/// piece hash (its first piece straddles the previous file's tail, verified
/// live). But the file's offset in the torrent's piece stream is known from
/// the files listing, so its first *fully contained* piece is too: matching
/// falls back to "same exact size, then hash `piece_size` bytes at
/// `probe_offset` and compare to `piece_hash`".
pub type SizeCandidate {
  SizeCandidate(
    torrent_hash: String,
    piece_hash: String,
    probe_offset: Int,
    piece_size: Int,
  )
}

pub type Index {
  Index(
    torrents: Dict(String, TorrentEntry),
    by_piece_hash: Dict(String, List(String)),
    by_file_size: Dict(Int, List(SizeCandidate)),
  )
}

type IndexState {
  IndexState(
    credentials: qbittorrent.Credentials,
    session: Session,
    index: Index,
    self: Subject(Message),
    recheck_delay_seconds: Int,
    resync_success_count: Int,
    resync_failure_count: Int,
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
          resync_success_count: 0,
          resync_failure_count: 0,
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
  Index(
    torrents: dict.new(),
    by_piece_hash: dict.new(),
    by_file_size: dict.new(),
  )
}

fn handle_message(
  state: IndexState,
  message: Message,
) -> actor.Next(IndexState, Message) {
  case message {
    // Refresh and Resync both hide seconds of latency (HTTP round-trips,
    // retry backoffs, the recheck delay), so their work runs in a spawned
    // worker on a snapshot of the state instead of inside the actor — a
    // Sonarr season import fires many events at once, and every one of them
    // needs Lookup/PieceSizes answered within the syncer's call timeout
    // while earlier resyncs are still in flight. The worker reports back
    // via IndexFetched/ResyncFinished, which is where state (index,
    // session, counters) actually changes.
    Refresh -> {
      let snapshot = state
      process.spawn_unlinked(fn() {
        let #(result, worker_state) = with_retry(snapshot, fetch_index_result)
        process.send(snapshot.self, IndexFetched(result, worker_state.session))
      })
      process.send_after(state.self, refresh_interval_ms, Refresh)
      actor.continue(state)
    }
    IndexFetched(result, session) -> {
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
      actor.continue(IndexState(..state, index:, session:))
    }
    Lookup(piece_hash, reply_to) -> {
      process.send(reply_to, find_match(state.index, piece_hash))
      actor.continue(state)
    }
    SizeCandidates(size, reply_to) -> {
      process.send(reply_to, size_candidates(state.index, size))
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
          resync_success_count: state.resync_success_count,
          resync_failure_count: state.resync_failure_count,
        ),
      )
      actor.continue(state)
    }
    Resync(torrent_hash, piece_hash, new_absolute_path, reply_to) -> {
      let snapshot = state
      process.spawn_unlinked(fn() {
        let #(result, worker_state) =
          resync_with_retry(
            snapshot,
            torrent_hash,
            piece_hash,
            new_absolute_path,
            snapshot.recheck_delay_seconds,
            1,
          )
        process.send(
          snapshot.self,
          ResyncFinished(
            ResyncOutcome(torrent_hash:, new_absolute_path:, result:),
            worker_state.session,
            reply_to,
          ),
        )
      })
      actor.continue(state)
    }
    ResyncFinished(outcome, session, reply_to) -> {
      let state = case outcome.result {
        Ok(Nil) ->
          IndexState(
            ..state,
            session:,
            resync_success_count: state.resync_success_count + 1,
          )
        Error(_) ->
          IndexState(
            ..state,
            session:,
            resync_failure_count: state.resync_failure_count + 1,
          )
      }
      process.send(reply_to, outcome)
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
    Ok(_), Ok(_), Ok(properties) if properties.infohash_v1 == "" -> {
      // Pure BitTorrent v2 torrent: qBittorrent doesn't expose real piece
      // hashes for these (verified live against 5.2.2, see
      // properties_decoder's doc comment) — indexing them would poison
      // by_piece_hash with garbage entries under this torrent's hash.
      logging.log(
        logging.Warning,
        "skipping torrent "
          <> summary.hash
          <> ": pure BitTorrent v2 torrent, qBittorrent does not expose usable piece hashes for it",
      )
      Error(Nil)
    }
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

  let by_file_size =
    list.fold(entries, dict.new(), fn(index, entry) {
      list.fold(file_probes(entry), index, fn(index, probe) {
        let #(size, candidate) = probe
        dict.upsert(index, size, fn(existing) {
          case existing {
            Some(candidates) -> [candidate, ..candidates]
            None -> [candidate]
          }
        })
      })
    })

  Index(torrents:, by_piece_hash:, by_file_size:)
}

/// One SizeCandidate per file that fully contains at least one piece,
/// walking the files in torrent order to know each one's offset in the
/// piece stream.
fn file_probes(entry: TorrentEntry) -> List(#(Int, SizeCandidate)) {
  let #(probes, _total_size) =
    list.fold(entry.files, #([], 0), fn(acc, file) {
      let #(probes, offset) = acc
      let probes = case probe_for(entry, file, offset) {
        Ok(candidate) -> [#(file.size, candidate), ..probes]
        Error(Nil) -> probes
      }
      #(probes, offset + file.size)
    })
  probes
}

fn probe_for(
  entry: TorrentEntry,
  file: TorrentFile,
  offset: Int,
) -> Result(SizeCandidate, Nil) {
  let piece_size = entry.piece_size
  let probe_offset = case offset % piece_size {
    0 -> 0
    remainder -> piece_size - remainder
  }
  let probe_piece = { offset + probe_offset } / piece_size
  let #(range_start, range_end) = file.piece_range
  // The file must fully contain the probe piece, and the piece index
  // computed from cumulative sizes must agree with the piece_range
  // qBittorrent reports — a mismatch would mean the files listing isn't in
  // torrent order and every offset here is garbage.
  case
    probe_offset + piece_size <= file.size
    && probe_piece >= range_start
    && probe_piece <= range_end
  {
    False -> Error(Nil)
    True ->
      entry.piece_hashes
      |> list.drop(probe_piece)
      |> list.first
      |> result.map(fn(piece_hash) {
        SizeCandidate(
          torrent_hash: entry.hash,
          piece_hash:,
          probe_offset:,
          piece_size:,
        )
      })
  }
}

pub fn size_candidates(index: Index, size: Int) -> List(SizeCandidate) {
  dict.get(index.by_file_size, size) |> result.unwrap([])
}

/// Keeps only the candidates whose expected piece hash actually matches the
/// file on disk — same exact size alone is coincidence, the piece hash is
/// the proof. Several survivors with different torrent hashes is the
/// cross-seed case, same as an Ambiguous match.
pub fn verify_size_candidates(
  path: String,
  candidates: List(SizeCandidate),
) -> List(SizeCandidate) {
  candidates
  |> list.filter(fn(candidate) {
    case
      piece_hasher.hash_piece_at(
        path,
        candidate.probe_offset,
        candidate.piece_size,
      )
    {
      Ok(hash) -> hash == candidate.piece_hash
      Error(_) -> False
    }
  })
  |> list.unique
}

pub fn find_match(index: Index, piece_hash: String) -> MatchResult {
  case dict.get(index.by_piece_hash, piece_hash) {
    Error(Nil) -> NoMatch
    Ok([]) -> NoMatch
    Ok([torrent_hash]) -> Matched(torrent_hash:, piece_hash:)
    Ok(candidates) -> Ambiguous(piece_hash:, candidates:)
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

  use _ <- result.try(case simplifile.file_info(new_absolute_path) {
    Ok(info) if info.size == file.size -> Ok(Nil)
    Ok(info) ->
      Error(SizeMismatch(torrent_hash:, expected: file.size, actual: info.size))
    // The file vanished between the fs event and now (or isn't statable) —
    // let the rename fail downstream with qBittorrent's own error rather
    // than inventing a size of 0 here.
    Error(_) -> Ok(Nil)
  })

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
