//// Path translation between qBittorrent's view of the filesystem and the
//// daemon's. Two independent mechanisms, both applied where torrent paths
//// enter (index build) and leave (setLocation):
////
//// - path mappings, like Sonarr/Radarr's Remote Path Mappings: qBittorrent
////   in a container can mount the media at a different path than the
////   daemon sees, and matching compares those paths literally.
//// - symlink canonicalization: macOS's /tmp is a symlink to /private/tmp
////   and FSEvents always reports the resolved form, so an unresolved
////   configured path never string-matches an event path.

import gleam/list
import gleam/string

pub type PathMapping {
  PathMapping(remote: String, local: String)
}

/// qBittorrent's form of a path -> the daemon's. Unmapped paths pass
/// through unchanged.
pub fn to_local(mappings: List(PathMapping), path: String) -> String {
  case list.find(mappings, fn(mapping) { applies(mapping.remote, path) }) {
    Ok(mapping) -> swap_prefix(path, mapping.remote, mapping.local)
    Error(Nil) -> path
  }
}

/// The daemon's form of a path -> qBittorrent's, for paths sent back to it
/// (setLocation).
pub fn to_remote(mappings: List(PathMapping), path: String) -> String {
  case list.find(mappings, fn(mapping) { applies(mapping.local, path) }) {
    Ok(mapping) -> swap_prefix(path, mapping.local, mapping.remote)
    Error(Nil) -> path
  }
}

// Boundary-aware, like torrent_index.relative_to: "/data/media" must not
// claim "/data/media2".
fn applies(prefix: String, path: String) -> Bool {
  path == prefix || string.starts_with(path, prefix <> "/")
}

fn swap_prefix(path: String, from: String, to: String) -> String {
  to <> string.drop_start(path, string.length(from))
}

/// Canonicalizes each mapping's `local` side once, where mappings enter the
/// system: every local path they get compared against is canonical, so a
/// mapping configured through a symlink (local = "/tmp/..." on macOS) would
/// otherwise never match in `to_remote`. `remote` stays literal — it only
/// exists on qBittorrent's filesystem.
pub fn canonicalize_locals(mappings: List(PathMapping)) -> List(PathMapping) {
  list.map(mappings, fn(mapping) {
    PathMapping(..mapping, local: canonicalize(mapping.local))
  })
}

/// Best-effort realpath: resolves symlinks in every component, returning
/// the input unchanged for anything unresolvable (non-existent paths
/// included — a remote-only save_path is fine, it just stays literal).
@external(erlang, "arr_sync_paths_ffi", "canonicalize")
pub fn canonicalize(path: String) -> String
