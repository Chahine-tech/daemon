-module(piece_hasher_ffi).
-export([hash_piece/3]).

%% Reads `Length` bytes at `Offset` from `Path` and returns their SHA1 hex
%% digest, without reading the rest of the file into memory.
hash_piece(Path, Offset, Length) ->
    case file:open(Path, [binary, read]) of
        {ok, IoDevice} ->
            Result = case file:pread(IoDevice, Offset, Length) of
                {ok, Data} ->
                    Hash = crypto:hash(sha, Data),
                    {ok, string:lowercase(binary:encode_hex(Hash))};
                _ ->
                    {error, too_small}
            end,
            file:close(IoDevice),
            Result;
        {error, _Reason} ->
            {error, cannot_open}
    end.
