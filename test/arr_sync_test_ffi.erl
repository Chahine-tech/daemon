-module(arr_sync_test_ffi).
-export([set_env/2, unset_env/1]).

set_env(Name, Value) ->
    os:putenv(binary_to_list(Name), binary_to_list(Value)),
    nil.

unset_env(Name) ->
    os:unsetenv(binary_to_list(Name)),
    nil.
