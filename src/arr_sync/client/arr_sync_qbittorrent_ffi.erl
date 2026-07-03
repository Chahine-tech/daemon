-module(arr_sync_qbittorrent_ffi).
-export([safe_call/1]).

%% gleam_httpc's error normalisation is incomplete: gleam_httpc_ffi:normalise_error/1
%% only recognises `failed_connect` and `timeout`; any other httpc-level error atom
%% (e.g. socket_closed_remotely, seen live when qBittorrent restarts mid-request)
%% falls through to `erlang:error({unexpected_httpc_error, Reason})` — an uncaught
%% exception, not a Result. Without this, that crashes the whole torrent_index actor
%% (and, via repeated crash-restart-crash, the daemon's supervisor past its restart
%% intensity) instead of surfacing as a retryable error.
safe_call(Thunk) ->
    try Thunk() of
        Result -> Result
    catch
        Class:Reason ->
            {error, {connection_lost, format_error(Class, Reason)}}
    end.

format_error(Class, Reason) ->
    unicode:characters_to_binary(io_lib:format("~p:~p", [Class, Reason])).
