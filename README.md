# arr-sync

> You rename a file, the seeding keeps going. Period.

[![test](https://github.com/Chahine-tech/daemon/actions/workflows/test.yml/badge.svg)](https://github.com/Chahine-tech/daemon/actions/workflows/test.yml)
![Gleam](https://img.shields.io/badge/gleam-%23FFAFF3.svg?style=flat)
![License](https://img.shields.io/badge/license-Apache--2.0-blue)

A daemon written in [Gleam](https://gleam.run) (BEAM/Erlang) that watches your media library and automatically resyncs qBittorrent whenever Sonarr/Radarr renames or moves a file.

---

## The problem

qBittorrent tracks a file by **path + filename**, not by content. Sonarr renames:

```
naruto.s01e01.xvid.mp4  →  Naruto (2002)/Season 01/Naruto - S01E01 - Enter Naruto Uzumaki.mkv
```

qBittorrent loses track of the file, seeding stops, peers are lost, your ratio evaporates. `arr-sync` gets rid of that: it detects the rename, finds the right torrent by **BitTorrent piece hash** (not by filename), and fixes qBittorrent on its own.

### Why not just hardlink instead?

A common workaround: have Sonarr/Radarr **hardlink** the renamed file into the media library instead of moving it, so the file qBittorrent is seeding never actually moves. Works, but only if downloads and media share the **same filesystem** (hardlinks can't cross filesystem/volume boundaries — separate Docker mounts break this), and qBittorrent keeps reporting the original, un-renamed filename forever.

`arr-sync` covers the general case: it works across filesystems/volumes/network shares, and qBittorrent ends up reporting the file's actual current path and name. If hardlinking already works for your setup, you probably don't need it.

---

## How it works

```
   fs_watcher                     torrent_index                           syncer
(inotify/FSEvents)              (qBittorrent session +              (orchestrates
                                 piece_hash -> torrent index)        it all)
|                               |                                   |
|-------------------------- Created(path) -------------------------->
|                               |                                   |
                                |<----------- PieceSizes -----------|
                                |--------- [32768, 262144] --------->
|                               |                                   |
                                (hash the file's first piece
                                 for each candidate size)
|                               |                                   |
                                |<---------- Lookup(hash) ----------|
                                |-------- Matched(torrent) --------->
|                               |                                   |
                                |<---------- Resync(...) -----------|
                                renameFile + (setLocation) + recheck
                                 on the qBittorrent side
```

Matching is done via **BitTorrent piece hashes** (SHA1 of the 16 KB–4 MB chunks that make up the torrent, listed in the `.torrent`) — they never change as long as the file's content doesn't, unlike its name.

---

## Architecture

| Module | Role |
|---|---|
| `arr_sync` | CLI (`start`/`match`/`list`/`resync`), OTP supervision tree |
| `arr_sync/syncer` | Subscribes to the watcher, orchestrates matching + resync |
| `arr_sync/matcher/torrent_index` | Actor holding the qBittorrent session + the `piece_hash → torrent` index, resolves piece → exact file, calls `renameFile`/`setLocation`/`recheck` |
| `arr_sync/matcher/piece_hasher` | Hashes a file's first pieces without ever loading the whole thing into memory |
| `arr_sync/watcher/fs_watcher` | Filesystem watcher (inotify/FSEvents/kqueue depending on the OS) |
| `arr_sync/client/qbittorrent` | HTTP client for the qBittorrent WebUI API |
| `arr_sync/client/sonarr` / `arr_sync/client/radarr` | Optional post-resync notifications |
| `arr_sync/config` | Parses `arr-sync.toml` |
| `arr_sync/logging` | RFC3339-timestamped logs |
| `arr_sync/distribution` | Distributed Erlang so `arr-sync status` can query a running daemon from a separate process |

Module names are global across the whole BEAM, so both layers are namespaced to avoid collisions with other packages: Gleam modules live under `arr_sync/` (matching the package name) instead of at the top of `src/`, and the two Erlang FFI shims (`arr_sync_piece_hasher_ffi.erl`, `arr_sync_fs_watcher_ffi.erl` — handling `file:pread`, `:crypto`, and the `:fs` lib, none of which Gleam or `gleam_stdlib` cover) are prefixed `arr_sync_` and colocated with the Gleam module that calls them.

---

## Installation

```sh
brew install gleam erlang    # or your package manager of choice
gleam deps download
cp arr-sync.toml.example arr-sync.toml    # fill in your qBittorrent credentials
make build                                # export the standalone OTP release into build/erlang-shipment
```

Re-run `make build` whenever the code changes — the other `make` targets run whatever was last built, they don't rebuild on their own.

## Usage

```sh
make start                              # run the full daemon
make start CONFIG=path/to/config.toml
make match FILE=/data/media/Show/episode.mkv    # test matching without touching qBittorrent
make list                               # list indexed torrents
make resync HASH=<torrent_hash>         # force a qBittorrent recheck
make status                             # query a running daemon (torrents indexed, piece sizes seen)
make run ARGS="..."                     # anything not covered by the targets above
make help                               # list all targets
```

Every target runs the exported `build/erlang-shipment/entrypoint.sh` (a standalone OTP release — no `gleam` toolchain needed at runtime) with the `ERL_FLAGS` needed to avoid the boot-crash risk described below. Calling `build/erlang-shipment/entrypoint.sh` directly bypasses that — don't.

## Config

`arr-sync.toml` — see [`arr-sync.toml.example`](./arr-sync.toml.example) for a full example.

| Section | Fields | Description |
|---|---|---|
| `[qbittorrent]` | `url`, `username`, `password` | qBittorrent WebUI |
| `[watch]` | `paths` | Watched directories |
| `[sync]` | `recheck_delay`, `min_file_size_mb` | Seconds to wait after `renameFile` before forcing a `recheck`; minimum file size (MB) before a Created event is worth hashing at all, to skip sidecar files (subtitles, `.nfo`, thumbnails) |
| `[sonarr]` *(optional)* | `url`, `api_key` | Post-resync notification |
| `[radarr]` *(optional)* | `url`, `api_key` | Post-resync notification |

---

## Status

**Works, checked against a live qBittorrent (Docker) and a real filesystem**: auth, `list/files/properties/pieceHashes`, `renameFile`/`setLocation`/`recheck`, the piece hasher (checked byte-for-byte against `shasum`), the filesystem watcher (real FSEvents stream), end-to-end resync on a renamed multi-file torrent, `arr-sync start` booting the full daemon, `arr-sync status` querying it live from a separate process.

**Not checked against a live instance**: Sonarr/Radarr notifications (HTTP client only, same shape as the qBittorrent one).

---

## Gotchas

### Path resolution gotcha: `/tmp` vs `/private/tmp` on macOS

On macOS, `/tmp` is a symlink to `/private/tmp`, and FSEvents always reports the **resolved** path — `fs_watcher` sees `/private/tmp/...` even if the file lives under `/tmp/...`. If qBittorrent's `save_path` for a torrent was set using the unresolved `/tmp/...` form (e.g. that's what was passed when the torrent was added), `relative_to` in `torrent_index.gleam` compares two paths that look different but point at the same file, the match fails, and the resync silently no-ops.

Not an `arr-sync` bug — FSEvents and qBittorrent simply don't agree on symlink resolution. Keep `[watch] paths` and qBittorrent's save paths on the same resolved form (`/private/tmp/...`), or better, avoid `/tmp` for real deployments entirely — it's wiped on reboot anyway, `/data/media` or similar is the right call.

### Boot-crash risk: `fs`'s native binary is missing

`fs` (the filesystem-watcher dependency) auto-starts as an OTP application dependency — `application:ensure_all_started('arr_sync')` starts it before `main/0` runs, outside `arr_sync_fs_watcher_ffi`'s own error handling. If the native watcher binary for the current OS is missing, its default `backwards_compatible` mode still tries to auto-spawn one at boot and crashes the whole VM, not just one watch path.

The `Makefile` sets `ERL_FLAGS="-fs backwards_compatible false"` before running the exported release to disable that auto-spawn — arr-sync's own per-path watchers (`fs_watcher.gleam`) start explicitly afterwards and already handle a missing binary cleanly (logged, not fatal). Calling `build/erlang-shipment/entrypoint.sh` directly bypasses this — don't.

### `arr-sync status`

The daemon becomes a distributed Erlang node on startup (`arr_sync@<hostname>`), authenticated with a per-install cookie generated on first run and stored in `.arr-sync-cookie` (mode 0600, gitignored — not the shared `~/.erlang.cookie`). `status` starts a short-lived node of its own and reaches the daemon over `rpc:call`. Localhost only by design: distributed Erlang RPC can run arbitrary code once connected, so this isn't meant to be exposed on a network.

Gotcha found while wiring this up: use `inet:gethostname()`, not `net_adm:localhost()`, to build the node name — the latter appends the machine's mDNS suffix (`.local` on macOS), which `node()` itself doesn't use, so the two ends disagree on the daemon's name.

---

## Contributing

See [`CONTRIBUTING.md`](./CONTRIBUTING.md) for dev setup, running tests, and implementation-level gotchas.
