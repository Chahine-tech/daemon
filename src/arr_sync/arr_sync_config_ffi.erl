-module(arr_sync_config_ffi).
-export([os_env/1]).

%% {error, nil} for unset AND for empty: docker compose substitutes an
%% undefined variable as "", and treating that as a real (empty) password
%% would shadow the one in the config file.
os_env(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        "" -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.
