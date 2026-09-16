%%%-------------------------------------------------------------------
%%% Per-node probe sessions: up / down / auth_error, schema refresh.
%%%-------------------------------------------------------------------
-module(mgmtd_ems_session_test).

-include_lib("eunit/include/eunit.hrl").

-export([init/2]).

-define(LISTENER, mgmtd_ems_session_test_listener).
-define(FIXTURE, mgmtd_ems_session_test_fixture).
-define(JSON, <<"application/yang-data+json">>).
-define(YANG, <<"application/yang">>).
-define(XRD, <<"application/xrd+xml">>).
-define(YANG_A,
        <<"module example {\n  namespace \"urn:ex:a\";\n  prefix a;\n}\n">>).
-define(YANG_B,
        <<"module example-b {\n  namespace \"urn:ex:b\";\n  prefix b;\n}\n">>).
-define(HOST_META,
        <<"<XRD xmlns='http://docs.oasis-open.org/ns/xri/xrd-1.0'>\n"
          "  <Link rel='restconf' href='/restconf'/>\n"
          "</XRD>\n">>).
-define(ERR_401,
        <<"{\"ietf-restconf:errors\":{\"error\":["
          "{\"error-tag\":\"access-denied\","
          "\"error-message\":\"authentication required\"}]}}">>).

session_test_() ->
    {setup, fun setup/0, fun teardown/1,
     fun(Port) ->
             [{"unreachable add is ok and down", fun() -> down_on_add() end},
              {"reachable probe is up and caches YANG",
               fun() -> up_and_schema(Port) end},
              {"401 is auth_error, last schema kept",
               fun() -> auth_error(Port) end},
              {"module-set-id change refetches on probe",
               fun() -> schema_refresh(Port) end},
              {"remove_node stops the session",
               fun() -> remove_stops(Port) end},
              {"seeded node is probed at boot",
               fun() -> seed_at_boot(Port) end}]
     end}.

setup() ->
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, _} = application:ensure_all_started(inets),
    application:load(mgmtd_ems),
    application:set_env(mgmtd_ems, probe_interval, 0),
    application:unset_env(mgmtd_ems, nodes),
    stop_stack(),
    try ets:delete(?FIXTURE) catch error:badarg -> ok end,
    ets:new(?FIXTURE, [named_table, public, set]),
    ets:insert(?FIXTURE, {mode, up}),
    ets:insert(?FIXTURE, {set_id, <<"set-a">>}),
    Dispatch = cowboy_router:compile([{'_', [{'_', ?MODULE, []}]}]),
    {ok, _} = cowboy:start_clear(?LISTENER, [{port, 0}],
                                 #{env => #{dispatch => Dispatch}}),
    ranch:get_port(?LISTENER).

teardown(_) ->
    stop_stack(),
    _ = cowboy:stop_listener(?LISTENER),
    try ets:delete(?FIXTURE) catch error:badarg -> ok end,
    application:unset_env(mgmtd_ems, nodes),
    application:unset_env(mgmtd_ems, probe_interval),
    ok.

start_ems() ->
    stop_stack(),
    {ok, Pid} = mgmtd_ems_sup:start_link(),
    unlink(Pid),
    Pid.

stop_stack() ->
    case whereis(mgmtd_ems_sup) of
        Sup when is_pid(Sup) ->
            unlink(Sup),
            _ = gen_server:stop(Sup),
            ok;
        undefined ->
            ok
    end,
    lists:foreach(
      fun(Name) ->
              case whereis(Name) of
                  undefined ->
                      ok;
                  P ->
                      unlink(P),
                      try gen_server:stop(P) catch _:_ -> ok end
              end
      end,
      [mgmtd_ems_sessions, mgmtd_ems_session_sup,
       mgmtd_ems_schema, mgmtd_ems_inventory]).

down_on_add() ->
    start_ems(),
    ?assertEqual(ok, mgmtd_ems:add_node(dead, #{host => "127.0.0.1", port => 1})),
    ?assertEqual({ok, down}, mgmtd_ems:probe(dead)),
    {ok, Node} = mgmtd_ems:node(dead),
    ?assertEqual(down, maps:get(status, Node)),
    ?assertEqual(undefined, maps:get(last_seen, Node)),
    ?assertEqual({error, no_schema}, mgmtd_ems:schema(dead)).

up_and_schema(Port) ->
    ets:insert(?FIXTURE, {mode, up}),
    ets:insert(?FIXTURE, {set_id, <<"set-a">>}),
    start_ems(),
    ?assertEqual(ok, mgmtd_ems:add_node(edge1, #{host => "127.0.0.1", port => Port})),
    ?assertEqual({ok, up}, mgmtd_ems:probe(edge1)),
    {ok, Node} = mgmtd_ems:node(edge1),
    ?assertEqual(up, maps:get(status, Node)),
    ?assertEqual(true, is_integer(maps:get(last_seen, Node))),
    ?assertEqual(<<"set-a">>, maps:get(schema_ref, Node)),
    {ok, Entry} = mgmtd_ems:schema(edge1),
    Example = find_mod(<<"example">>, maps:get(modules, Entry)),
    ?assertEqual(?YANG_A, maps:get(yang, Example)).

auth_error(Port) ->
    ets:insert(?FIXTURE, {mode, up}),
    ets:insert(?FIXTURE, {set_id, <<"set-a">>}),
    start_ems(),
    ok = mgmtd_ems:add_node(edge1, #{host => "127.0.0.1", port => Port}),
    {ok, up} = mgmtd_ems:probe(edge1),
    {ok, Before} = mgmtd_ems:schema(edge1),
    ets:insert(?FIXTURE, {mode, auth}),
    ?assertEqual({ok, auth_error}, mgmtd_ems:probe(edge1)),
    {ok, Node} = mgmtd_ems:node(edge1),
    ?assertEqual(auth_error, maps:get(status, Node)),
    ?assertEqual(<<"set-a">>, maps:get(schema_ref, Node)),
    {ok, After} = mgmtd_ems:schema(edge1),
    ?assertEqual(maps:get(id, Before), maps:get(id, After)).

schema_refresh(Port) ->
    ets:insert(?FIXTURE, {mode, up}),
    ets:insert(?FIXTURE, {set_id, <<"set-a">>}),
    start_ems(),
    ok = mgmtd_ems:add_node(edge1, #{host => "127.0.0.1", port => Port}),
    {ok, up} = mgmtd_ems:probe(edge1),
    ets:insert(?FIXTURE, {set_id, <<"set-b">>}),
    {ok, up} = mgmtd_ems:probe(edge1),
    {ok, Node} = mgmtd_ems:node(edge1),
    ?assertEqual(<<"set-b">>, maps:get(schema_ref, Node)),
    {ok, Entry} = mgmtd_ems:schema(edge1),
    ?assertEqual(<<"set-b">>, maps:get(id, Entry)),
    ExampleB = find_mod(<<"example-b">>, maps:get(modules, Entry)),
    ?assertEqual(?YANG_B, maps:get(yang, ExampleB)),
    ?assertEqual([<<"set-a">>, <<"set-b">>],
                 lists:sort(mgmtd_ems_schema:ids())).

remove_stops(Port) ->
    ets:insert(?FIXTURE, {mode, up}),
    start_ems(),
    ok = mgmtd_ems:add_node(edge1, #{host => "127.0.0.1", port => Port}),
    {ok, up} = mgmtd_ems:probe(edge1),
    ?assertEqual(ok, mgmtd_ems:remove_node(edge1)),
    ?assertEqual({error, not_found}, mgmtd_ems:node(edge1)),
    ?assertEqual({error, not_found}, mgmtd_ems:probe(edge1)).

seed_at_boot(Port) ->
    stop_stack(),
    application:set_env(mgmtd_ems, nodes,
                        [{seed1, #{host => "127.0.0.1", port => Port}}]),
    application:set_env(mgmtd_ems, probe_interval, 0),
    ets:insert(?FIXTURE, {mode, up}),
    ets:insert(?FIXTURE, {set_id, <<"set-a">>}),
    start_ems(),
    {ok, _} = wait_name(seed1),
    ?assertEqual({ok, up}, mgmtd_ems:probe(seed1)),
    {ok, Node} = mgmtd_ems:node(seed1),
    ?assertEqual(up, maps:get(status, Node)).

wait_name(Name) ->
    wait_name(Name, 50).

wait_name(Name, 0) ->
    mgmtd_ems:node(Name);
wait_name(Name, N) ->
    case mgmtd_ems:node(Name) of
        {ok, _} = Ok ->
            Ok;
        {error, not_found} ->
            timer:sleep(20),
            wait_name(Name, N - 1)
    end.

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
    case ets:lookup_element(?FIXTURE, mode, 2) of
        auth ->
            cowboy_req:reply(401, #{<<"content-type">> => ?JSON}, ?ERR_401, Req);
        up ->
            SetId = ets:lookup_element(?FIXTURE, set_id, 2),
            Body = mgmtd_ems_json:encode(
                     #{<<"ietf-yang-library:modules-state">> =>
                           #{<<"module-set-id">> => SetId,
                             <<"module">> => modules(SetId)}}),
            cowboy_req:reply(200, #{<<"content-type">> => ?JSON}, Body, Req)
    end;
dispatch(<<"GET">>, <<"/restconf/yang/example">>, Req) ->
    cowboy_req:reply(200, #{<<"content-type">> => ?YANG}, ?YANG_A, Req);
dispatch(<<"GET">>, <<"/restconf/yang/example-b">>, Req) ->
    cowboy_req:reply(200, #{<<"content-type">> => ?YANG}, ?YANG_B, Req);
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
       <<"schema">> => <<"/restconf/yang/example">>}];
modules(<<"set-b">>) ->
    [#{<<"name">> => <<"example-b">>,
       <<"revision">> => <<>>,
       <<"namespace">> => <<"urn:ex:b">>,
       <<"conformance-type">> => <<"implement">>,
       <<"schema">> => <<"/restconf/yang/example-b">>}].
