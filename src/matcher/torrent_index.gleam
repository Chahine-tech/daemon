import client/qbittorrent.{type Session}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import logging

pub type TorrentFile {
  TorrentFile(name: String, size: Int, progress: Float)
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

// No file_index here: a piece hash identifies the torrent, not a specific
// file within it — multi-file torrents share piece boundaries across files.
// Resolving to a single file needs piece_length (not yet fetched) plus
// cumulative file offsets, which is a separate, real chunk of work.
pub type MatchResult {
  Matched(torrent_hash: String)
  NoMatch
  Ambiguous(candidates: List(String))
}

pub type Message {
  Refresh
  Lookup(piece_hash: String, reply_to: Subject(MatchResult))
  Shutdown
}

pub type Index {
  Index(
    torrents: Dict(String, TorrentEntry),
    by_piece_hash: Dict(String, List(String)),
  )
}

type IndexState {
  IndexState(session: Session, index: Index)
}

pub fn start(
  credentials: qbittorrent.Credentials,
  name: process.Name(Message),
) -> actor.StartResult(Subject(Message)) {
  actor.new_with_initialiser(5000, fn(subject) {
    case qbittorrent.login(credentials) {
      Ok(session) ->
        actor.initialised(IndexState(session:, index: empty_index()))
        |> actor.returning(subject)
        |> Ok
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
      let index = fetch_index(state.session)
      actor.continue(IndexState(..state, index:))
    }
    Lookup(piece_hash, reply_to) -> {
      process.send(reply_to, find_match(state.index, piece_hash))
      actor.continue(state)
    }
    Shutdown -> actor.stop()
  }
}

pub fn fetch_index(session: Session) -> Index {
  case qbittorrent.list_torrents(session) {
    Error(_reason) -> {
      logging.log(logging.Warning, "could not list torrents from qBittorrent")
      empty_index()
    }
    Ok(summaries) ->
      summaries
      |> list.filter_map(fn(summary) { fetch_entry(session, summary) })
      |> build_index
  }
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
          TorrentFile(name: file.name, size: file.size, progress: file.progress)
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

  let by_piece_hash =
    list.fold(entries, dict.new(), fn(index, entry) {
      list.fold(entry.piece_hashes, index, fn(index, piece_hash) {
        dict.upsert(index, piece_hash, fn(existing) {
          case existing {
            Some(torrent_hashes) -> [entry.hash, ..torrent_hashes]
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
    Ok([torrent_hash]) -> Matched(torrent_hash:)
    Ok(candidates) -> Ambiguous(candidates:)
  }
}
