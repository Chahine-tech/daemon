-module(arr_sync_distribution_ffi).
-export([fixed_name/1, ensure_started/2, node_name/0, ping/1,
         write_cookie_if_absent/2, random_cookie/0, os_pid/0, rpc_query_status/2]).

%% Deterministic Name(msg) (no random suffix, unlike gleam_erlang's
%% process.new_name/1) so a function invoked over RPC by a separate node
%% can reconstruct the exact same Name and find the already-running actor.
fixed_name(Prefix) ->
    binary_to_atom(Prefix, utf8).

%% Turns the current node into a distributed one under ShortName@localhost.
%% @localhost explicitly, not the machine's hostname: the distribution
%% listener is bound to loopback (see ERL_FLAGS in the Makefile/Dockerfile),
%% and a hostname that resolves to a non-loopback address — the norm inside
%% a Docker container, where it maps to the container IP — would make the
%% CLI dial an address nobody listens on (found live: `status` worked on
%% macOS but not in Docker).
%% net_kernel:start/1 requires epmd to already be listening — unlike
%% `erl -name`, it does not start epmd itself when called after boot — so
%% this starts it first if needed.
ensure_started(ShortName, Cookie) ->
    case net_kernel:get_state() of
        #{started := no} ->
            os:cmd("epmd -daemon"),
            Name = binary_to_atom(<<ShortName/binary, "@localhost">>, utf8),
            case start_distribution(Name, 20) of
                {ok, _Pid} ->
                    erlang:set_cookie(binary_to_atom(Cookie, utf8)),
                    {ok, nil};
                {error, Reason} ->
                    {error, format_error(Reason)}
            end;
        _Started ->
            erlang:set_cookie(binary_to_atom(Cookie, utf8)),
            {ok, nil}
    end.

%% epmd was just spawned above via os:cmd and may not be listening on its
%% port yet — net_kernel:start fails with {'EXIT', nodistribution} deep in
%% its error tuple until it is. Rather than pattern-match that shape (liable
%% to shift across OTP versions) or guess a single fixed delay, retry with a
%% short backoff up to ~0.5s, which resolves in 1-2 iterations in practice
%% and copes better than a blind sleep when epmd is slow to bind (e.g. a
%% loaded CI runner).
start_distribution(Name, Retries) ->
    case net_kernel:start([Name, shortnames]) of
        {ok, Pid} ->
            {ok, Pid};
        {error, Reason} when Retries =< 0 ->
            {error, Reason};
        {error, _Reason} ->
            timer:sleep(25),
            start_distribution(Name, Retries - 1)
    end.

node_name() ->
    unicode:characters_to_binary(atom_to_list(node())).

ping(NodeName) ->
    net_adm:ping(binary_to_atom(NodeName, utf8)) =:= pong.

%% Writes Content to Path only if Path doesn't already exist, atomically —
%% closing the race where two processes (e.g. `arr-sync start` and a
%% concurrent `arr-sync status`) both see the cookie file missing and both
%% try to create it. Writes to a per-process temp file (already chmod'd
%% 0600, so the permission never differs from what ends up under Path) then
%% claims Path with a hard link, which POSIX guarantees fails with EEXIST if
%% another process's link won the race first — in which case this one's
%% content is simply discarded and the caller re-reads whatever is on disk.
write_cookie_if_absent(Path, Content) ->
    PathList = binary_to_list(Path),
    Tmp = PathList ++ "." ++ os:getpid() ++ ".tmp",
    case file:write_file(Tmp, Content) of
        ok -> claim_path(Tmp, PathList);
        {error, Reason} -> {error, format_error(Reason)}
    end.

claim_path(Tmp, PathList) ->
    Result =
        case file:change_mode(Tmp, 8#600) of
            ok ->
                case file:make_link(Tmp, PathList) of
                    ok -> {ok, nil};
                    {error, eexist} -> {ok, nil};
                    {error, Reason} -> {error, format_error(Reason)}
                end;
            {error, Reason} ->
                {error, format_error(Reason)}
        end,
    file:delete(Tmp),
    Result.

random_cookie() ->
    string:lowercase(binary:encode_hex(crypto:strong_rand_bytes(24))).

os_pid() ->
    unicode:characters_to_binary(os:getpid()).

rpc_query_status(NodeName, Timeout) ->
    Node = binary_to_atom(NodeName, utf8),
    case rpc:call(Node, 'arr_sync@distribution', query_status, [], Timeout) of
        {badrpc, Reason} -> {error, format_error(Reason)};
        Result -> {ok, Result}
    end.

format_error(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).
