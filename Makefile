.PHONY: help build run start status list match resync test format format-check clean check-build

SHIPMENT_DIR := build/erlang-shipment

# fs (the filesystem-watcher dependency) auto-starts as an OTP application
# before main/0 runs, independently of arr_sync_fs_watcher_ffi's own error
# handling. If its native watcher binary is missing for the current OS,
# fs's default backwards_compatible mode can crash the whole VM at boot —
# see "Boot-crash risk" in README.md. This disables that auto-spawn; arr-sync's
# own per-path watchers still start explicitly afterwards and handle a
# missing binary cleanly.
export ERL_FLAGS += -fs backwards_compatible false

help:
	@echo "make build                             export a standalone OTP release (re-run after every code change)"
	@echo "make run ARGS=\"...\"                     run the release with arbitrary CLI args"
	@echo "make start [CONFIG=path/to/config.toml] run the full daemon"
	@echo "make status                            query a running daemon"
	@echo "make list                              list indexed torrents"
	@echo "make match FILE=/data/media/x.mkv      test matching without touching qBittorrent"
	@echo "make resync HASH=<torrent_hash>        force a qBittorrent recheck"
	@echo "make test                              run the test suite"
	@echo "make format / make format-check"
	@echo "make clean                             remove build/"

build:
	gleam export erlang-shipment

check-build:
	@test -x $(SHIPMENT_DIR)/entrypoint.sh || { echo "error: $(SHIPMENT_DIR) not built — run 'make build' first" >&2; exit 1; }

run: check-build
	@$(SHIPMENT_DIR)/entrypoint.sh run $(ARGS)

start: check-build
	@$(SHIPMENT_DIR)/entrypoint.sh run start $(if $(CONFIG),--config $(CONFIG))

status: check-build
	@$(SHIPMENT_DIR)/entrypoint.sh run status

list: check-build
	@$(SHIPMENT_DIR)/entrypoint.sh run list

match: check-build
	@$(SHIPMENT_DIR)/entrypoint.sh run match $(FILE)

resync: check-build
	@$(SHIPMENT_DIR)/entrypoint.sh run resync $(HASH)

test:
	gleam test

format:
	gleam format

format-check:
	gleam format --check

clean:
	rm -rf build
