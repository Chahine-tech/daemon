# Contributing

## Dev setup

```sh
gleam deps download
docker compose up -d     # disposable qBittorrent to test the HTTP client against a real instance
```

## Running checks

```sh
make test               # 24 tests, no network required (or: gleam test)
make format-check        # or: gleam format --check
```

## qBittorrent API quirks

Worth knowing if you're touching `client/qbittorrent.gleam`:

- Login replies **204** on success on qBittorrent 5.x, not 200
- `progress` can be a bare JSON integer (`1`) instead of a float (`1.0`) once a file is complete
- `piece_size` isn't in `torrents/info`, only in `torrents/properties`
- `setLocation` alone doesn't fix a rename — without `renameFile`, the torrent drops to 0% instead of resyncing
- `torrents/files` includes a `piece_range` per file, which avoids computing cumulative file offsets by hand
