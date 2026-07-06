-module(arr_sync_piece_hasher_ffi).
-export([hash_piece/3, hash_piece_v2/3]).

%% Reads `Length` bytes at `Offset` from `Path` and returns their SHA1 hex
%% digest — a BitTorrent v1 piece hash — without reading the rest of the
%% file into memory.
hash_piece(Path, Offset, Length) ->
    with_piece(Path, Offset, Length, fun(Data) ->
        crypto:hash(sha, Data)
    end).

%% BitTorrent v2 (BEP 52) piece hash of the `PieceLength` bytes at `Offset`:
%% the SHA256 merkle root over the piece's 16 KiB blocks, padded with
%% zero-hashes up to PieceLength div 16384 leaves (a power of two, since
%% piece lengths are powers of two >= 16 KiB — a single leaf is its own
%% root). Verified against the piece layers of a real qBittorrent-created
%% v2 torrent.
hash_piece_v2(Path, Offset, PieceLength) ->
    with_piece(Path, Offset, PieceLength, fun(Data) ->
        BlocksPerPiece = PieceLength div 16384,
        Leaves = block_hashes(Data),
        Padding = lists:duplicate(BlocksPerPiece - length(Leaves), <<0:256>>),
        merkle_root(Leaves ++ Padding)
    end).

with_piece(Path, Offset, Length, HashFun) ->
    case file:open(Path, [binary, read]) of
        {ok, IoDevice} ->
            Result = case file:pread(IoDevice, Offset, Length) of
                {ok, Data} ->
                    {ok, string:lowercase(binary:encode_hex(HashFun(Data)))};
                _ ->
                    {error, too_small}
            end,
            file:close(IoDevice),
            Result;
        {error, _Reason} ->
            {error, cannot_open}
    end.

block_hashes(<<Block:16384/binary, Rest/binary>>) ->
    [crypto:hash(sha256, Block) | block_hashes(Rest)];
block_hashes(<<>>) ->
    [];
block_hashes(PartialBlock) ->
    [crypto:hash(sha256, PartialBlock)].

merkle_root([Root]) ->
    Root;
merkle_root(Hashes) ->
    merkle_root(pair_hashes(Hashes)).

pair_hashes([First, Second | Rest]) ->
    [crypto:hash(sha256, <<First/binary, Second/binary>>) | pair_hashes(Rest)];
pair_hashes([]) ->
    [].
