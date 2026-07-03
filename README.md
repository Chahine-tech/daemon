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

All modules live under `arr_sync/` (matching the package name) rather than at the top of `src/` — Gleam's module namespace is global across the whole BEAM, so generic directory names like `client/` or `watcher/` at the top level risk colliding with another package's modules.

Two small Erlang shims (`arr_sync_piece_hasher_ffi.erl`, `arr_sync_fs_watcher_ffi.erl`) handle the low-level work that neither Gleam nor `gleam_stdlib` covers (`file:pread`, `:crypto`, the `:fs` lib) — colocated with their Gleam module, prefixed `arr_sync_` so they don't collide in Erlang's global (unlike Gleam's, not namespaced by directory) module namespace.

---

## Installation

```sh
brew install gleam erlang    # or your package manager of choice
gleam deps download
cp arr-sync.toml.example arr-sync.toml    # fill in your qBittorrent credentials
```

## Usage

```sh
arr-sync start                                 # run the full daemon
arr-sync start --config path/to/config.toml
arr-sync match /data/media/Show/episode.mkv    # test matching without touching qBittorrent
arr-sync list                                  # list indexed torrents
arr-sync resync <torrent_hash>                 # force a qBittorrent recheck
```

## Config

`arr-sync.toml` — see [`arr-sync.toml.example`](./arr-sync.toml.example) for a full example.

| Section | Fields | Description |
|---|---|---|
| `[qbittorrent]` | `url`, `username`, `password` | qBittorrent WebUI |
| `[watch]` | `paths` | Watched directories |
| `[sync]` | `recheck_delay`, `min_file_size_mb` | Resync tuning |
| `[sonarr]` *(optional)* | `url`, `api_key` | Post-resync notification |
| `[radarr]` *(optional)* | `url`, `api_key` | Post-resync notification |

---

## Status

**Works, checked against a live qBittorrent (Docker) and a real filesystem**: auth, `list/files/properties/pieceHashes`, `renameFile`/`setLocation`/`recheck`, the piece hasher (checked byte-for-byte against `shasum`), the filesystem watcher (real FSEvents stream), end-to-end resync on a renamed multi-file torrent.

**Not checked against a live instance**: Sonarr/Radarr notifications (HTTP client only, same shape as the qBittorrent one).

**Not implemented**: `arr-sync status` — would need distributed Erlang to query an already-running daemon; it errors out cleanly instead of crashing.

### qBittorrent API quirks

Worth knowing if you're touching `client/qbittorrent.gleam`:

- Login replies **204** on success on qBittorrent 5.x, not 200
- `progress` can be a bare JSON integer (`1`) instead of a float (`1.0`) once a file is complete
- `piece_size` isn't in `torrents/info`, only in `torrents/properties`
- `setLocation` alone doesn't fix a rename — without `renameFile`, the torrent drops to 0% instead of resyncing
- `torrents/files` includes a `piece_range` per file, which avoids computing cumulative file offsets by hand

---

## Development

```sh
gleam test               # 25 tests, no network required
gleam format --check
docker compose up -d     # disposable qBittorrent to retest the HTTP client for real
```
