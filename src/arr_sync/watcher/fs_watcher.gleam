import arr_sync/logging
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor

pub type FsEvent {
  Created(path: String)
  Deleted(path: String)
}

pub type Message {
  Subscribe(listener: Subject(FsEvent))
  RawEvent(Result(#(String, List(String)), Nil))
  Shutdown
}

type WatcherState {
  WatcherState(listeners: List(Subject(FsEvent)))
}

pub fn start(
  paths: List(String),
  name: process.Name(Message),
) -> actor.StartResult(Subject(Message)) {
  actor.new_with_initialiser(1000, fn(subject) {
    list.index_map(paths, fn(path, index) {
      case watch(int.to_string(index), path) {
        Ok(Nil) -> Nil
        Error(reason) ->
          // Loud on purpose: a path that silently isn't watched means
          // renames under it will never trigger a resync, with nothing in
          // the logs to explain why.
          logging.log(logging.Error, "not watching " <> path <> ": " <> reason)
      }
    })

    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_other(fn(raw) { RawEvent(decode_raw_event(raw)) })

    actor.initialised(WatcherState(listeners: []))
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_message)
  |> actor.named(name)
  |> actor.start
}

fn handle_message(
  state: WatcherState,
  message: Message,
) -> actor.Next(WatcherState, Message) {
  case message {
    Subscribe(listener) ->
      actor.continue(WatcherState(listeners: [listener, ..state.listeners]))
    RawEvent(Ok(#(path, flags))) -> {
      case classify(path, flags) {
        Some(fs_event) ->
          list.each(state.listeners, fn(listener) {
            process.send(listener, fs_event)
          })
        None -> Nil
      }
      actor.continue(state)
    }
    RawEvent(Error(Nil)) -> actor.continue(state)
    Shutdown -> actor.stop()
  }
}

// FSEvents (macOS) and inotify (Linux) don't hand us matched from/to pairs
// for renames the way a higher-level watcher would — they report each path
// independently with a set of flags. So `renamed` here only tells us "this
// path changed identity", not what it used to be; we surface it as Created
// and let the syncer's piece-hash matching figure out which torrent (if
// any) it belongs to, since that doesn't require knowing the old path.
//
// Verified live against a real FSEvents stream: a plain file write reports
// flags like [created, modified, xattrmod] — `isfile` is NOT reliably
// present, so we can't require it. `isdir`, when present, is trustworthy
// enough to filter out directory-only events.
@internal
pub fn classify(path: String, flags: List(String)) -> option.Option(FsEvent) {
  case list.contains(flags, "isdir") {
    True -> None
    False ->
      case list.contains(flags, "removed") {
        True -> Some(Deleted(path))
        False ->
          case
            list.contains(flags, "created")
            || list.contains(flags, "renamed")
            || list.contains(flags, "modified")
          {
            True -> Some(Created(path))
            False -> None
          }
      }
  }
}

@external(erlang, "arr_sync_fs_watcher_ffi", "watch")
fn watch(name: String, path: String) -> Result(Nil, String)

@external(erlang, "arr_sync_fs_watcher_ffi", "decode_raw_event")
fn decode_raw_event(raw: Dynamic) -> Result(#(String, List(String)), Nil)
