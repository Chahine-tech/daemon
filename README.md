# arr-sync

> You rename a file, the seeding keeps going. Period.

[![test](https://github.com/Chahine-tech/arr-sync/actions/workflows/test.yml/badge.svg)](https://github.com/Chahine-tech/arr-sync/actions/workflows/test.yml)
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

Matching is done via **BitTorrent piece hashes** (SHA1 of the 16 KB–4 MB chunks that make up the torrent, listed in the `.torrent`) — they never change as long as the file's content doesn't, unlike its name. If several torrents share the matched piece (the same content cross-seeded on multiple trackers), every one of them gets resynced. Resyncs run concurrently: a season-sized import doesn't queue behind the first file's recheck.

Files that don't start on a piece boundary (every file but the first in a v1 multi-file torrent without pad files — pieces don't align to file boundaries in v1) can't be matched by their first bytes, so matching falls back to exact file size, verified by hashing the file's first *fully contained* piece at its known offset inside the file. A file too small to fully contain any piece stays unmatchable — below the typical piece size, that's sidecar territory anyway.

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

### Docker (recommended)

```yaml
services:
  arr-sync:
    image: ghcr.io/chahine-tech/arr-sync:latest
    restart: unless-stopped    # also retries until qBittorrent is up at boot
    environment:
      - QBITTORRENT_PASSWORD=${QBITTORRENT_PASSWORD}
    volumes:
      - ./arr-sync.toml:/config/arr-sync.toml:ro
      - /data/media:/data/media    # must be the SAME path qBittorrent sees
```

The one rule that matters: **arr-sync must be able to make sense of qBittorrent's paths**. Simplest way: mount the same volume at the same place in both containers. If the mounts differ (qBittorrent sees `/data/media`, arr-sync sees `/media`), declare it — exactly like Sonarr/Radarr's Remote Path Mappings:

```toml
[[path_mappings]]
remote = "/data/media"    # as qBittorrent reports it
local = "/media"          # the same directory as arr-sync sees it
```

`arr-sync status` inside the container:

```sh
docker exec <container> /app/entrypoint.sh run status
```

### From source

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
| `[qbittorrent]` | `url`, `username`, `password` | qBittorrent WebUI. `password` can be omitted if the `QBITTORRENT_PASSWORD` env var is set (it wins over the file either way) |
| `[watch]` | `paths` | Watched directories |
| `[sync]` | `recheck_delay`, `min_file_size_mb` | Seconds to wait after `renameFile` before forcing a `recheck`; minimum file size (MB) before a Created event is worth hashing at all, to skip sidecar files (subtitles, `.nfo`, thumbnails) |
| `[[path_mappings]]` *(optional, repeatable)* | `remote`, `local` | Like Sonarr/Radarr's Remote Path Mappings: `remote` is a path prefix as qBittorrent reports it, `local` is the same directory as arr-sync sees it. Needed when qBittorrent runs in a container that mounts the media somewhere else |
| `[sonarr]` *(optional)* | `url`, `api_key` | Post-resync disk rescan (`RescanSeries`) — catches Sonarr up when the rename didn't come from Sonarr itself |
| `[radarr]` *(optional)* | `url`, `api_key` | Post-resync disk rescan (`RescanMovie`), same idea |

---

## Status

**Works, checked against a live qBittorrent (Docker) and a real filesystem**: auth, `list/files/properties/pieceHashes`, `renameFile`/`setLocation`/`recheck`, the piece hasher (checked byte-for-byte against `shasum`), the filesystem watcher (real FSEvents stream), end-to-end resync on a renamed multi-file torrent, `arr-sync start` booting the full daemon, `arr-sync status` querying it live from a separate process (including the resync success/failure counters — both a real resync failure and a real success were triggered and observed via `status`), hybrid (v1+v2) BitTorrent torrents matching correctly out of the box, two files moved at once resyncing in parallel (`status` answered mid-flight), a cross-seeded file (two torrents, same content, different infohashes) resyncing both torrents, a non-piece-aligned interior file of a v1 multi-file torrent without pad files matching via the by-size fallback and resyncing, pure v2-only torrents (single-file and multi-file) matching via their exported piece layers and resyncing, a qBittorrent container mounting the media at a different path than the daemon (bridged by a `[[path_mappings]]` entry configured through a symlink, exercising both the mapping and the canonicalization) resyncing a cross-tree move end-to-end, the Sonarr and Radarr post-resync rescans landing as `completed | successful` in both apps' command histories.

---

## Gotchas

### Pure BitTorrent v2 torrents work — around a qBittorrent bug

Hybrid (v1+v2) torrents work with no extra setup — qBittorrent reports their v1 SHA1 piece hashes unchanged. Pure v2-only torrents are trickier: qBittorrent's `pieceHashes` endpoint doesn't return real hashes for them (verified against 5.2.2 — it's raw bytes from the torrent's own metadata, not actual piece hashes, a qBittorrent/libtorrent bug). `arr-sync` sidesteps the broken endpoint entirely: it fetches the original `.torrent` via `torrents/export`, parses the bencode itself, and reads the real SHA256 piece hashes from the v2 piece layers — then matches by computing the BEP 52 merkle root of a file's first piece (every v2 file starts on a piece boundary, so no alignment games needed). Verified live: single-file and multi-file pure v2 torrents both resync end-to-end.

The one v2 leftover: a file no larger than one piece has no piece-layer entry in the torrent, so it can't be piece-matched — irrelevant for media files, which dwarf every standard piece size.

### Symlinked paths (macOS `/tmp`, etc.)

Watchers report **resolved** paths (on macOS, FSEvents turns `/tmp/...` into `/private/tmp/...` — `/tmp` is a symlink), while qBittorrent stores whatever literal form it was given. Comparing the two used to silently no-op the resync. `arr-sync` now canonicalizes every path before comparing (save paths, mapping targets, event paths), so symlinked prefixes on the arr-sync side just work — verified live with a `/tmp`-form config against `/private/tmp` events. Paths that only exist on qBittorrent's side (behind a path mapping) stay literal, as they should.

### Boot-crash risk: `fs`'s native binary is missing

`fs` (the filesystem-watcher dependency) auto-starts as an OTP application dependency — `application:ensure_all_started('arr_sync')` starts it before `main/0` runs, outside `arr_sync_fs_watcher_ffi`'s own error handling. If the native watcher binary for the current OS is missing, its default `backwards_compatible` mode still tries to auto-spawn one at boot and crashes the whole VM, not just one watch path.

The `Makefile` sets `ERL_FLAGS="-fs backwards_compatible false"` before running the exported release to disable that auto-spawn — arr-sync's own per-path watchers (`fs_watcher.gleam`) start explicitly afterwards and already handle a missing binary cleanly (logged, not fatal). Calling `build/erlang-shipment/entrypoint.sh` directly bypasses this — don't.

### `arr-sync status`

The daemon becomes a distributed Erlang node on startup (`arr_sync@localhost`), authenticated with a per-install cookie generated on first run and stored in `.arr-sync-cookie` (mode 0600, gitignored — not the shared `~/.erlang.cookie`). `status` starts a short-lived node of its own and reaches the daemon over `rpc:call`. Localhost only, and enforced: distributed Erlang RPC can run arbitrary code once connected, and both the distribution listener and epmd default to listening on **every** interface — so the `Makefile` and the `Dockerfile` pin them to loopback (`-kernel inet_dist_use_interface '{127,0,0,1}'` and `ERL_EPMD_ADDRESS=127.0.0.1`, verified with `lsof`/LAN probes). One more reason not to call `entrypoint.sh` directly.

The node is named `arr_sync@localhost` rather than `arr_sync@<hostname>` on purpose: with the listener bound to loopback, `status` must dial an address that actually resolves to loopback, and a machine's hostname often doesn't — inside a Docker container it resolves to the container IP (found live: `status` worked on macOS but not in Docker until the name was pinned).

---

## Contributing

See [`CONTRIBUTING.md`](./CONTRIBUTING.md) for dev setup, running tests, and implementation-level gotchas.
