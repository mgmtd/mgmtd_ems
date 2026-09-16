%%%-------------------------------------------------------------------
%% @doc YANG schema cache, keyed by yang-library `module-set-id`.
%%
%% Fetch path is RFC 8040: host-meta → modules-state → each `schema` URL
%% as `application/yang`. Identical fingerprints share one cache entry.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_ems_schema).

-behaviour(gen_server).

-export([start_link/0,
         lookup/1,
         ids/0,
         discover/1,
         yang_library/1,
         sync/1,
         sync/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(TABLE, ?MODULE).
-define(YANG_ACCEPT, "application/yang").
-define(XRD_ACCEPT, "application/xrd+xml").
-define(YANGLIB_PATH, "data/ietf-yang-library:modules-state").
-define(DEFAULT_ROOT, "/restconf").

-type node_map() :: map().
-type cache_entry() :: #{
                         id := binary(),
                         fetched_at := integer(),
                         modules := [map()]
                        }.

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec lookup(binary() | string()) -> {ok, cache_entry()} | {error, not_found}.
lookup(Id) ->
    case ets:lookup(?TABLE, to_bin(Id)) of
        [{_, Entry}] ->
            {ok, Entry};
        [] ->
            {error, not_found}
    end.

-spec ids() -> [binary()].
ids() ->
    [Id || {Id, _} <- ets:tab2list(?TABLE)].

-spec discover(node_map()) -> {ok, string()} | {error, term()}.
discover(Node) ->
    case mgmtd_ems_restconf:request(
           Node, get, "/.well-known/host-meta", undefined,
           #{accept => ?XRD_ACCEPT}) of
        {ok, 200, _Hdrs, Body} ->
            {ok, restconf_root(Body)};
        {ok, 404, _, _} ->
            {ok, ?DEFAULT_ROOT};
        {ok, Status, _, Body} ->
            {error, {http, Status, Body}};
        {error, _} = Err ->
            Err
    end.

-spec yang_library(node_map()) -> {ok, map()} | {error, term()}.
yang_library(Node) ->
    case maps:get(restconf_root, Node, undefined) of
        undefined ->
            case discover(Node) of
                {ok, Root} ->
                    yang_library(Node, Root);
                {error, _} = Err ->
                    Err
            end;
        Root ->
            yang_library(Node, Root)
    end.

-spec sync(node_map()) -> {ok, cache_entry(), string()} | {error, term()}.
sync(Node) ->
    sync(Node, #{}).

-spec sync(node_map(), #{force => boolean()}) ->
          {ok, cache_entry(), string()} | {error, term()}.
sync(Node, Opts) ->
    case discover(Node) of
        {error, _} = Err ->
            Err;
        {ok, Root} ->
            case yang_library(Node, Root) of
                {error, _} = Err ->
                    Err;
                {ok, State} ->
                    Id = maps:get(id, State),
                    case maps:get(force, Opts, false) of
                        false ->
                            case lookup(Id) of
                                {ok, Entry} ->
                                    {ok, Entry, Root};
                                {error, not_found} ->
                                    fetch_and_store(Node, Root, State)
                            end;
                        true ->
                            fetch_and_store(Node, Root, State)
                    end
            end
    end.

init([]) ->
    ets:new(?TABLE, [named_table, set, protected, {read_concurrency, true}]),
    {ok, #{}}.

handle_call({put, Entry}, _From, State) ->
    ets:insert(?TABLE, {maps:get(id, Entry), Entry}),
    {reply, ok, State};
handle_call({put_engine, Entry0}, _From, State) ->
    Id = maps:get(id, Entry0),
    Entry = try load_engine(Entry0) of
                {ok, E} ->
                    destroy_old_ctx(Id),
                    E;
                {error, _} ->
                    Entry0
            catch
                _:_ ->
                    Entry0
            end,
    ets:insert(?TABLE, {Id, Entry}),
    {reply, {ok, Entry}, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

yang_library(Node, Root) ->
    Path = string:trim(to_list(Root), trailing, "/") ++ "/" ++ ?YANGLIB_PATH,
    case mgmtd_ems_restconf:request(Node, get, Path) of
        {ok, 200, _Hdrs, Body} ->
            decode_modules_state(Body);
        {ok, Status, _, Body} ->
            {error, {http, Status, Body}};
        {error, _} = Err ->
            Err
    end.

fetch_and_store(Node, Root, State) ->
    case fetch_modules(Node, Root, maps:get(modules, State)) of
        {error, _} = Err ->
            Err;
        {ok, Mods} ->
            Entry0 = #{id => maps:get(id, State),
                       fetched_at => erlang:system_time(second),
                       modules => Mods},
            case gen_server:call(?SERVER, {put_engine, Entry0}, 30000) of
                {ok, Entry} ->
                    {ok, Entry, Root};
                {error, _} = Err ->
                    Err
            end
    end.

load_engine(Entry) ->
    Ctx = mgmtd_schema:new_ctx(),
    YangMap = yang_map(maps:get(modules, Entry)),
    Implement = [M || M <- maps:get(modules, Entry),
                      maps:get(conformance, M, <<"implement">>) =:= <<"implement">>,
                      maps:is_key(yang, M)],
    case mgmtd_schema:with_ctx(Ctx, fun() -> load_implement(Implement, YangMap) end) of
        ok ->
            {ok, Entry#{ctx => Ctx}};
        {error, _} = Err ->
            mgmtd_schema:destroy_ctx(Ctx),
            Err
    end.

load_implement([], _YangMap) ->
    ok;
load_implement([Mod | Rest], YangMap) ->
    Bin = maps:get(yang, Mod),
    case mgmtd:load_yang_module_binary(Bin, #{yang_modules => YangMap,
                                              yang_source => Bin}) of
        ok ->
            load_implement(Rest, YangMap);
        {error, _} = Err ->
            Err
    end.

yang_map(Mods) ->
    maps:from_list(
      [{maps:get(name, M), maps:get(yang, M)}
       || M <- Mods, maps:is_key(yang, M)]).

destroy_old_ctx(Id) ->
    case ets:lookup(?TABLE, Id) of
        [{_, #{ctx := Ctx}}] ->
            mgmtd_schema:destroy_ctx(Ctx);
        _ ->
            ok
    end.

fetch_modules(Node, Root, Mods) ->
    fetch_modules(Node, Root, Mods, []).

fetch_modules(_Node, _Root, [], Acc) ->
    {ok, lists:reverse(Acc)};
fetch_modules(Node, Root, [Mod | Rest], Acc) ->
    case maps:get(schema_uri, Mod, undefined) of
        undefined ->
            fetch_modules(Node, Root, Rest, [Mod | Acc]);
        Uri ->
            Path = schema_path(Uri, Root),
            case mgmtd_ems_restconf:request(
                   Node, get, Path, undefined,
                   #{accept => ?YANG_ACCEPT}) of
                {ok, 200, _, Yang} ->
                    fetch_modules(Node, Root, Rest,
                                  [Mod#{yang => Yang} | Acc]);
                {ok, Status, _, Body} ->
                    {error, {schema_fetch, maps:get(name, Mod), Status, Body}};
                {error, Reason} ->
                    {error, {schema_fetch, maps:get(name, Mod), Reason}}
            end
    end.

decode_modules_state(Body) ->
    case mgmtd_ems_json:decode(Body) of
        {error, _} = Err ->
            Err;
        {ok, Map} when is_map(Map) ->
            case modules_state(Map) of
                error ->
                    {error, {invalid_yang_library, Map}};
                State ->
                    {ok, State}
            end;
        {ok, Other} ->
            {error, {invalid_yang_library, Other}}
    end.

modules_state(#{<<"ietf-yang-library:modules-state">> := State}) ->
    parse_state(State);
modules_state(#{<<"modules-state">> := State}) ->
    parse_state(State);
modules_state(_) ->
    error.

parse_state(State) when is_map(State) ->
    Id = to_bin(maps:get(<<"module-set-id">>, State, <<>>)),
    Raw = maps:get(<<"module">>, State, []),
    #{id => Id,
      modules => [normalize_module(M) || M <- as_list(Raw)]};
parse_state(_) ->
    error.

normalize_module(M) when is_map(M) ->
    Base = #{name => to_bin(maps:get(<<"name">>, M, <<>>)),
             revision => to_bin(maps:get(<<"revision">>, M, <<>>)),
             namespace => to_bin(maps:get(<<"namespace">>, M, <<>>)),
             conformance => to_bin(maps:get(<<"conformance-type">>, M,
                                            <<"implement">>))},
    case maps:get(<<"schema">>, M, undefined) of
        undefined ->
            Base;
        Uri ->
            Base#{schema_uri => to_bin(Uri)}
    end.

as_list(L) when is_list(L) ->
    L;
as_list(M) when is_map(M) ->
    [M].

restconf_root(Body) ->
    Bin = iolist_to_binary(Body),
    case href(Bin, rel_then_href()) of
        {ok, Href} ->
            href_path(Href);
        error ->
            case href(Bin, href_then_rel()) of
                {ok, Href} ->
                    href_path(Href);
                error ->
                    ?DEFAULT_ROOT
            end
    end.

rel_then_href() ->
    "rel\\s*=\\s*['\"]restconf['\"][^>]*href\\s*=\\s*['\"]([^'\"]+)['\"]".

href_then_rel() ->
    "href\\s*=\\s*['\"]([^'\"]+)['\"][^>]*rel\\s*=\\s*['\"]restconf['\"]".

href(Bin, Re) ->
    case re:run(Bin, Re, [{capture, [1], list}, caseless]) of
        {match, [Href]} ->
            {ok, Href};
        nomatch ->
            error
    end.

href_path(Href) ->
    case uri_string:parse(Href) of
        #{path := Path} when Path =/= "", Path =/= undefined ->
            to_list(Path);
        _ ->
            case Href of
                "/" ++ _ ->
                    Href;
                _ ->
                    ?DEFAULT_ROOT
            end
    end.

schema_path(Uri, Root) ->
    S = to_list(Uri),
    case uri_string:parse(S) of
        #{scheme := Scheme, path := Path}
          when Scheme =/= undefined, Path =/= undefined, Path =/= "" ->
            to_list(Path);
        #{path := Path} when Path =/= undefined, Path =/= "" ->
            relative_schema(to_list(Path), Root);
        _ ->
            relative_schema(S, Root)
    end.

relative_schema("/" ++ _ = Path, _Root) ->
    Path;
relative_schema("restconf/" ++ _ = Path, _Root) ->
    "/" ++ Path;
relative_schema(Path, Root) ->
    string:trim(to_list(Root), trailing, "/") ++ "/" ++ Path.

to_bin(B) when is_binary(B) ->
    B;
to_bin(L) when is_list(L) ->
    unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) ->
    atom_to_binary(A, utf8);
to_bin(N) when is_integer(N) ->
    integer_to_binary(N).

to_list(B) when is_binary(B) ->
    binary_to_list(B);
to_list(L) when is_list(L) ->
    L;
to_list(A) when is_atom(A) ->
    atom_to_list(A).
