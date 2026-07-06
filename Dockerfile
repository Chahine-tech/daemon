FROM ghcr.io/gleam-lang/gleam:v1.17.0-erlang-alpine AS build
WORKDIR /build
COPY gleam.toml manifest.toml ./
RUN gleam deps download
COPY src ./src
RUN gleam export erlang-shipment

# Runtime is the same image as the build stage so the Erlang/OTP running
# the shipment is exactly the one that compiled it.
FROM ghcr.io/gleam-lang/gleam:v1.17.0-erlang-alpine

# The fs watcher dependency shells out to inotifywait on Linux — without
# inotify-tools the daemon boots but never sees a single file event.
RUN apk add --no-cache inotify-tools

COPY --from=build /build/build/erlang-shipment /app

# Same hardening as the Makefile (see README "Gotchas"): don't let fs
# auto-spawn a watcher at boot, and keep distributed Erlang + epmd bound to
# loopback — `arr-sync status` works via docker exec, nothing listens on
# the container network.
ENV ERL_FLAGS="-fs backwards_compatible false -kernel inet_dist_use_interface {127,0,0,1}"
ENV ERL_EPMD_ADDRESS=127.0.0.1

# `start` reads ./arr-sync.toml, and the .arr-sync-cookie authenticating
# `status` is created next to it — mount the config file at
# /config/arr-sync.toml.
WORKDIR /config

ENTRYPOINT ["/app/entrypoint.sh", "run"]
CMD ["start"]
