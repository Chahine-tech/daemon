# Contributing

## Dev setup

```sh
gleam deps download
docker compose up -d     # disposable qBittorrent to test the HTTP client against a real instance
```

## Running checks

```sh
make test               # 25 tests, no network required (or: gleam test)
make format-check        # or: gleam format --check
```

## qBittorrent API quirks

Worth knowing if you're touching `client/qbittorrent.gleam`:

- Login replies **204** on success on qBittorrent 5.x, not 200
- `progress` can be a bare JSON integer (`1`) instead of a float (`1.0`) once a file is complete
- `piece_size` isn't in `torrents/info`, only in `torrents/properties`
- `setLocation` alone doesn't fix a rename — without `renameFile`, the torrent drops to 0% instead of resyncing
- `torrents/files` includes a `piece_range` per file, which avoids computing cumulative file offsets by hand
- `torrents/pieceHashes` is broken for pure BitTorrent v2 torrents (verified live against 5.2.2): instead of real hashes, it returns the raw bencoded bytes of the torrent's own `info` dict, sliced into 20-byte chunks and hex-encoded as if they were SHA1 — a qBittorrent/libtorrent bug, not something a client can work around. Hybrid (v1+v2) torrents are unaffected: this endpoint reports their v1 SHA1 hashes unchanged, so they match correctly with no v2-specific code. `properties.infohash_v1` (empty only for pure v2 torrents) is how `torrent_index.fetch_entry` tells the two cases apart and skips the former instead of indexing garbage.
