-module(arr_sync_paths_ffi).
-export([canonicalize/1]).

%% Best-effort realpath. OTP has no realpath: file:read_link/1 only resolves
%% a path that is itself a symlink, not symlinked parents, so this walks the
%% components resolving each one. Bounded to 40 hops like glibc, in case of
%% symlink loops; anything unresolvable (enoent included) keeps its literal
%% form, so paths that only exist on qBittorrent's side pass through.
canonicalize(Path) ->
    PathList = binary_to_list(Path),
    Resolved = resolve(filename:split(PathList), "", 40),
    unicode:characters_to_binary(Resolved).

resolve([], Acc, _HopsLeft) ->
    Acc;
resolve([Component | Rest], Acc, HopsLeft) when HopsLeft > 0 ->
    Candidate = case Acc of
        "" -> Component;
        _ -> filename:join(Acc, Component)
    end,
    case file:read_link(Candidate) of
        {ok, Target} ->
            Absolute = case filename:pathtype(Target) of
                absolute -> Target;
                _ -> filename:join(Acc, Target)
            end,
            %% The target may itself contain symlinked components: restart
            %% resolution from scratch over target ++ remaining components.
            resolve(filename:split(Absolute) ++ Rest, "", HopsLeft - 1);
        {error, _} ->
            resolve(Rest, Candidate, HopsLeft)
    end;
resolve(Rest, Acc, _HopsLeft) ->
    %% Hop budget exhausted (symlink loop): give back what we have, literal.
    filename:join([Acc | Rest]).
