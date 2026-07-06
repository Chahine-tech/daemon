# Contributing

## Dev setup

```sh
gleam deps download
docker compose up -d     # disposable qBittorrent to test the HTTP client against a real instance
```

## Running checks

```sh
make test               # 50 tests, no network required (or: gleam test)
make format-check        # or: gleam format --check
```

## Sonarr/Radarr API quirk

The v3 `command` endpoint answers 201 for any known command name — including ones that then **fail inside the app**. The legacy `DownloadedEpisodesScan`/`DownloadedMoviesScan` commands do exactly that on a live Sonarr 4.x/Radarr 5.x (`failed | unknown` in the command history, invisible at the HTTP layer). `RescanSeries`/`RescanMovie` are the ones that actually complete; if you touch these clients, check the command history, not just the status code.

## qBittorrent API quirks

Worth knowing if you're touching `client/qbittorrent.gleam`:

- Login replies **204** on success on qBittorrent 5.x, not 200
- `progress` can be a bare JSON integer (`1`) instead of a float (`1.0`) once a file is complete
- `piece_size` isn't in `torrents/info`, only in `torrents/properties`
- `setLocation` alone doesn't fix a rename — without `renameFile`, the torrent drops to 0% instead of resyncing
- `torrents/files` includes a `piece_range` per file, which avoids computing cumulative file offsets by hand
- `torrents/pieceHashes` is broken for pure BitTorrent v2 torrents (verified live against 5.2.2): instead of real hashes, it returns the raw bencoded bytes of the torrent's own `info` dict, sliced into 20-byte chunks and hex-encoded as if they were SHA1 — a qBittorrent/libtorrent bug. Hybrid (v1+v2) torrents are unaffected: this endpoint reports their v1 SHA1 hashes unchanged. `properties.infohash_v1` (empty only for pure v2 torrents) is how `torrent_index.fetch_entry` tells the two cases apart — and for the pure v2 case, it bypasses the broken endpoint entirely: `torrents/export` returns the original `.torrent`, `matcher/torrent_file.gleam` parses the bencode and reads the SHA256 hashes from the v2 piece layers, and matching hashes files with the BEP 52 merkle scheme (16 KiB blocks, zero-padded) instead of flat SHA1.
