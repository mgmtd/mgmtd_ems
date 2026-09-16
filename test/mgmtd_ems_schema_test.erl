%%%-------------------------------------------------------------------
%%% Discovery, yang-library, and module-set-id YANG cache.
%%%-------------------------------------------------------------------
-module(mgmtd_ems_schema_test).

-include_lib("eunit/include/eunit.hrl").

-export([init/2]).

-define(LISTENER, mgmtd_ems_schema_test_listener).
-define(FIXTURE, mgmtd_ems_schema_test_fixture).
-define(JSON, <<"application/yang-data+json">>).
-define(YANG, <<"application/yang">>).
-define(XRD, <<"application/xrd+xml">>).

-define(YANG_A,
        <<"module example {\n  namespace \"urn:ex:a\";\n  prefix a;\n"
          "  container only-a { leaf x { type string; } }\n}\n">>).
-define(YANG_B,
        <<"module example-b {\n  namespace \"urn:ex:b\";\n  prefix b;\n"
          "  container only-b { leaf y { type uint8; } }\n}\n">>).
-define(YANG_INET,
        <<"module ietf-inet-types {\n  namespace \"urn:ietf:params:xml:ns:yang:ietf-inet-types\";\n  prefix inet;\n}\n">>).
-define(HOST_META,
        <<"<XRD xmlns='http://docs.oasis-open.org/ns/xri/xrd-1.0'>\n"
          "  <Link rel='restconf' href='/restconf'/>\n"
          "</XRD>\n">>).

schema_test_() ->
    {setup, fun setup/0, fun teardown/1,
     fun(Node) ->
             [{"discover host-meta", fun() -> discover(Node) end},
              {"yang-library", fun() -> yang_library(Node) end},
              {"sync cache lifecycle", fun() -> cache_lifecycle(Node) end},
              {"schema before sync", fun() -> no_schema_yet(Node) end},
              {"unknown node", fun() -> unknown_node() end}]
     end}.

setup() ->
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, _} = application:ensure_all_started(inets),
    application:load(mgmtd_ems),
    application:unset_env(mgmtd_ems, nodes),
    case whereis(mgmtd_ems_sup) of
        Sup when is_pid(Sup) ->
            unlink(Sup),
            _ = gen_server:stop(Sup);
        undefined ->
            ok
    end,
    stop_named(mgmtd_ems_inventory),
    stop_named(mgmtd_ems_schema),
    try ets:delete(?FIXTURE) catch error:badarg -> ok end,
    ets:new(?FIXTURE, [named_table, public, set]),
    ets:insert(?FIXTURE, {set_id, <<"set-a">>}),
    {ok, _} = mgmtd_ems_inventory:start_link(),
    {ok, _} = mgmtd_ems_schema:start_link(),
    Dispatch = cowboy_router:compile([{'_', [{'_', ?MODULE, []}]}]),
    {ok, _} = cowboy:start_clear(?LISTENER, [{port, 0}],
                                 #{env => #{dispatch => Dispatch}}),
    Port = ranch:get_port(?LISTENER),
    Node = #{host => "127.0.0.1", port => Port, tls => false},
    ok = mgmtd_ems:add_node(edge1, Node),
    ok = mgmtd_ems:add_node(edge2, Node),
    Node.

teardown(_) ->
    stop_named(mgmtd_ems_inventory),
    stop_named(mgmtd_ems_schema),
    _ = cowboy:stop_listener(?LISTENER),
    try ets:delete(?FIXTURE) catch error:badarg -> ok end,
    ok.

stop_named(Name) ->
    case whereis(Name) of
        undefined ->
            ok;
        Pid ->
            gen_server:stop(Pid)
    end.

discover(_Node) ->
    ?assertEqual({ok, "/restconf"}, mgmtd_ems:discover(edge1)),
    {ok, Rec} = mgmtd_ems:node(edge1),
    ?assertEqual("/restconf", maps:get(restconf_root, Rec)).

yang_library(_Node) ->
    {ok, State} = mgmtd_ems:yang_library(edge1),
    ?assertEqual(<<"set-a">>, maps:get(id, State)),
    Names = [maps:get(name, M) || M <- maps:get(modules, State)],
    ?assert(lists:member(<<"example">>, Names)),
    ?assert(lists:member(<<"ietf-inet-types">>, Names)),
    ?assert(lists:member(<<"ietf-yang-library">>, Names)).

cache_lifecycle(_Node) ->
    {ok, Entry} = mgmtd_ems:sync_schema(edge1),
    ?assertEqual(<<"set-a">>, maps:get(id, Entry)),
    Example = find_mod(<<"example">>, maps:get(modules, Entry)),
    ?assertEqual(?YANG_A, maps:get(yang, Example)),
    Inet = find_mod(<<"ietf-inet-types">>, maps:get(modules, Entry)),
    ?assertEqual(?YANG_INET, maps:get(yang, Inet)),
    Lib = find_mod(<<"ietf-yang-library">>, maps:get(modules, Entry)),
    ?assertEqual(false, maps:is_key(yang, Lib)),
    {ok, Cached} = mgmtd_ems:schema(edge1),
    ?assertEqual(Entry, Cached),
    {ok, Rec} = mgmtd_ems:node(edge1),
    ?assertEqual(<<"set-a">>, maps:get(schema_ref, Rec)),
    {ok, SnapA} = mgmtd_ems:schema_snapshot(edge1),
    ?assertEqual([<<"example">>],
                 [maps:get(<<"name">>, M) || M <- maps:get(<<"modules">>, SnapA)]),
    [ModA] = maps:get(<<"modules">>, SnapA),
    ?assertEqual([<<"only-a">>],
                 [maps:get(<<"name">>, C) || C <- maps:get(<<"children">>, ModA)]),
    {ok, A} = mgmtd_ems:sync_schema(edge1),
    {ok, B} = mgmtd_ems:sync_schema(edge2),
    ?assertEqual(maps:get(id, A), maps:get(id, B)),
    ?assertEqual([<<"set-a">>], lists:sort(mgmtd_ems_schema:ids())),
    ets:insert(?FIXTURE, {set_id, <<"set-b">>}),
    {ok, EntryB} = mgmtd_ems:sync_schema(edge1),
    ?assertEqual(<<"set-b">>, maps:get(id, EntryB)),
    ExampleB = find_mod(<<"example-b">>, maps:get(modules, EntryB)),
    ?assertEqual(?YANG_B, maps:get(yang, ExampleB)),
    ?assertEqual([<<"set-a">>, <<"set-b">>],
                 lists:sort(mgmtd_ems_schema:ids())),
    {ok, Rec2} = mgmtd_ems:node(edge1),
    ?assertEqual(<<"set-b">>, maps:get(schema_ref, Rec2)),
    {ok, SnapB} = mgmtd_ems:schema_snapshot(edge1),
    NamesB = [maps:get(<<"name">>, M) || M <- maps:get(<<"modules">>, SnapB)],
    ?assertEqual([<<"example-b">>], NamesB).

no_schema_yet(_Node) ->
    ok = mgmtd_ems:add_node(fresh, #{host => "127.0.0.1", port => 9}),
    ?assertEqual({error, no_schema}, mgmtd_ems:schema(fresh)),
    ?assertEqual({error, no_schema}, mgmtd_ems:schema_snapshot(fresh)).

unknown_node() ->
    ?assertEqual({error, not_found}, mgmtd_ems:discover(missing)),
    ?assertEqual({error, not_found}, mgmtd_ems:sync_schema(missing)).

find_mod(Name, Mods) ->
    case [M || M <- Mods, maps:get(name, M) =:= Name] of
        [M] ->
            M;
        [] ->
            error({not_found, Name, Mods})
    end.

init(Req0, State) ->
    {ok, dispatch(cowboy_req:method(Req0), cowboy_req:path(Req0), Req0), State}.

dispatch(<<"GET">>, <<"/.well-known/host-meta">>, Req) ->
    cowboy_req:reply(200, #{<<"content-type">> => ?XRD}, ?HOST_META, Req);
dispatch(<<"GET">>, <<"/restconf/data/ietf-yang-library:modules-state">>, Req) ->
    SetId = ets:lookup_element(?FIXTURE, set_id, 2),
    Body = mgmtd_ems_json:encode(
             #{<<"ietf-yang-library:modules-state">> =>
                   #{<<"module-set-id">> => SetId,
                     <<"module">> => modules(SetId)}}),
    cowboy_req:reply(200, #{<<"content-type">> => ?JSON}, Body, Req);
dispatch(<<"GET">>, <<"/restconf/yang/example">>, Req) ->
    cowboy_req:reply(200, #{<<"content-type">> => ?YANG}, ?YANG_A, Req);
dispatch(<<"GET">>, <<"/restconf/yang/example-b">>, Req) ->
    cowboy_req:reply(200, #{<<"content-type">> => ?YANG}, ?YANG_B, Req);
dispatch(<<"GET">>, <<"/restconf/yang/ietf-inet-types">>, Req) ->
    cowboy_req:reply(200, #{<<"content-type">> => ?YANG}, ?YANG_INET, Req);
dispatch(_, _, Req) ->
    cowboy_req:reply(404, #{<<"content-type">> => ?JSON},
                     <<"{\"ietf-restconf:errors\":{\"error\":["
                       "{\"error-tag\":\"invalid-value\"}]}}">>,
                     Req).

modules(<<"set-a">>) ->
    [#{<<"name">> => <<"example">>,
       <<"revision">> => <<>>,
       <<"namespace">> => <<"urn:ex:a">>,
       <<"conformance-type">> => <<"implement">>,
       <<"schema">> => <<"/restconf/yang/example">>},
     #{<<"name">> => <<"ietf-inet-types">>,
       <<"revision">> => <<"2013-07-15">>,
       <<"namespace">> => <<"urn:ietf:params:xml:ns:yang:ietf-inet-types">>,
       <<"conformance-type">> => <<"import">>,
       <<"schema">> => <<"/restconf/yang/ietf-inet-types">>},
     #{<<"name">> => <<"ietf-yang-library">>,
       <<"revision">> => <<"2016-06-21">>,
       <<"namespace">> => <<"urn:ietf:params:xml:ns:yang:ietf-yang-library">>,
       <<"conformance-type">> => <<"implement">>}];
modules(<<"set-b">>) ->
    [#{<<"name">> => <<"example-b">>,
       <<"revision">> => <<>>,
       <<"namespace">> => <<"urn:ex:b">>,
       <<"conformance-type">> => <<"implement">>,
       <<"schema">> => <<"/restconf/yang/example-b">>}].
