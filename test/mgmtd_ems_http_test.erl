%%%-------------------------------------------------------------------
%%% In-process Cowboy stand-in for a mgmtd RESTCONF node.
%%%-------------------------------------------------------------------
-module(mgmtd_ems_http_test).

-include_lib("eunit/include/eunit.hrl").

-export([init/2]).

-define(LISTENER, mgmtd_ems_http_test_listener).
-define(JSON, <<"application/yang-data+json">>).
-define(YANG, <<"application/yang">>).
-define(ETAG, <<"\"v1\"">>).

-define(FOO_JSON,
        <<"{\"ex:foo\":{\"bar\":1}}">>).
-define(YANG_BODY,
        <<"module example {\n  namespace \"urn:ex\";\n  prefix ex;\n}\n">>).
-define(ERR_JSON,
        <<"{\"ietf-restconf:errors\":{\"error\":["
          "{\"error-type\":\"protocol\","
          "\"error-tag\":\"access-denied\","
          "\"error-message\":\"authentication required\"}]}}">>).

http_test_() ->
    {setup, fun setup/0, fun teardown/1,
     fun(Node) ->
             [{"GET JSON + ETag", fun() -> get_json(Node) end},
              {"GET YANG", fun() -> get_yang(Node) end},
              {"GET query", fun() -> get_query(Node) end},
              {"401 error envelope", fun() -> get_denied(Node) end},
              {"PUT If-Match + map body", fun() -> put_if_match(Node) end},
              {"PUT missing If-Match", fun() -> put_precondition(Node) end},
              {"POST", fun() -> post_item(Node) end},
              {"PATCH", fun() -> patch_item(Node) end},
              {"public API via inventory", fun() -> via_inventory(Node) end}]
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
    stop_inventory(),
    {ok, _} = mgmtd_ems_inventory:start_link(),
    Dispatch = cowboy_router:compile([{'_', [{'_', ?MODULE, []}]}]),
    {ok, _} = cowboy:start_clear(?LISTENER, [{port, 0}],
                                 #{env => #{dispatch => Dispatch}}),
    Port = ranch:get_port(?LISTENER),
    Node = #{host => "127.0.0.1", port => Port, tls => false},
    ok = mgmtd_ems:add_node(http1, Node),
    Node.

teardown(_) ->
    stop_inventory(),
    _ = cowboy:stop_listener(?LISTENER),
    ok.

stop_inventory() ->
    case whereis(mgmtd_ems_inventory) of
        undefined ->
            ok;
        Pid ->
            gen_server:stop(Pid)
    end.

get_json(Node) ->
    {ok, 200, Hdrs, Body} =
        mgmtd_ems_restconf:request(Node, get, "data/ex:foo"),
    ?assertEqual(?FOO_JSON, Body),
    ?assertEqual("\"v1\"", mgmtd_ems_restconf:etag(Hdrs)),
    {ok, #{<<"ex:foo">> := #{<<"bar">> := 1}}} =
        mgmtd_ems_restconf:decode_json(Body).

get_yang(Node) ->
    {ok, 200, Hdrs, Body} =
        mgmtd_ems_restconf:request(Node, get, "yang/example", undefined,
                                   #{accept => "application/yang"}),
    ?assertEqual(?YANG_BODY, Body),
    RawCT = string:lowercase(mgmtd_ems_restconf:header("content-type", Hdrs)),
    CT = string:trim(hd(string:split(RawCT, ";"))),
    ?assertEqual("application/yang", CT).

get_query(Node) ->
    {ok, 200, _Hdrs, Body} =
        mgmtd_ems_restconf:request(
          Node, get, "data/echo", undefined,
          #{query => [{"with-defaults", "trim"}]}),
    {ok, Map} = mgmtd_ems_restconf:decode_json(Body),
    ?assertEqual(<<"trim">>, maps:get(<<"with-defaults">>, Map)).

get_denied(Node) ->
    {ok, 401, _Hdrs, Body} =
        mgmtd_ems_restconf:request(Node, get, "data/denied"),
    [Err] = mgmtd_ems_restconf:errors(Body),
    ?assertEqual(<<"access-denied">>, maps:get(<<"error-tag">>, Err)),
    ?assertEqual(<<"authentication required">>,
                 maps:get(<<"error-message">>, Err)).

put_if_match(Node) ->
    {ok, 204, _Hdrs, Body} =
        mgmtd_ems_restconf:request(
          Node, put, "data/ex:foo",
          #{<<"ex:foo">> => #{<<"bar">> => 2}},
          #{etag => "\"v1\""}),
    ?assertEqual(<<>>, Body).

put_precondition(Node) ->
    {ok, 412, _Hdrs, Body} =
        mgmtd_ems_restconf:request(
          Node, put, "data/ex:foo", <<"{\"ex:foo\":{}}">>, #{}),
    [Err] = mgmtd_ems_restconf:errors(Body),
    ?assertEqual(<<"operation-failed">>, maps:get(<<"error-tag">>, Err)).

post_item(Node) ->
    {ok, 201, Hdrs, _Body} =
        mgmtd_ems_restconf:request(
          Node, post, "data/ex:list",
          #{<<"ex:item">> => [#{<<"name">> => <<"n1">>}]}),
    ?assertEqual("/restconf/data/ex:list=n1",
                 mgmtd_ems_restconf:header("location", Hdrs)).

patch_item(Node) ->
    {ok, 204, _, <<>>} =
        mgmtd_ems_restconf:request(
          Node, patch, "data/ex:foo", <<"{\"ex:foo\":{\"bar\":3}}">>).

via_inventory(Node) ->
    {ok, 200, _, Yang} =
        mgmtd_ems:get(http1, "yang/example",
                      #{accept => "application/yang"}),
    ?assertEqual(?YANG_BODY, Yang),
    {ok, 201, _, _} =
        mgmtd_ems:post(http1, "data/ex:list",
                       #{<<"ex:item">> => [#{<<"name">> => <<"n2">>}]}),
    {ok, 204, _, _} =
        mgmtd_ems:put(http1, "data/ex:foo",
                      #{<<"ex:foo">> => #{<<"bar">> => 9}},
                      #{etag => "\"v1\""}),
    _ = Node,
    ok.

%% Cowboy callback
init(Req0, State) ->
    {ok, dispatch(cowboy_req:method(Req0), cowboy_req:path(Req0), Req0), State}.

dispatch(<<"GET">>, <<"/restconf/data/ex:foo">>, Req) ->
    cowboy_req:reply(200,
                     #{<<"content-type">> => ?JSON,
                       <<"etag">> => ?ETAG},
                     ?FOO_JSON, Req);
dispatch(<<"GET">>, <<"/restconf/data/echo">>, Req) ->
    Qs = cowboy_req:parse_qs(Req),
    Map = maps:from_list(Qs),
    cowboy_req:reply(200, #{<<"content-type">> => ?JSON},
                     mgmtd_ems_json:encode(Map), Req);
dispatch(<<"GET">>, <<"/restconf/data/denied">>, Req) ->
    cowboy_req:reply(401,
                     #{<<"content-type">> => ?JSON,
                       <<"www-authenticate">> => <<"Basic realm=\"mgmtd\"">>},
                     ?ERR_JSON, Req);
dispatch(<<"GET">>, <<"/restconf/yang/example">>, Req) ->
    cowboy_req:reply(200, #{<<"content-type">> => ?YANG}, ?YANG_BODY, Req);
dispatch(<<"GET">>, <<"/restconf/yang/example/", _/binary>>, Req) ->
    cowboy_req:reply(200, #{<<"content-type">> => ?YANG}, ?YANG_BODY, Req);
dispatch(<<"PUT">>, <<"/restconf/data/ex:foo">>, Req0) ->
    IfMatch = cowboy_req:header(<<"if-match">>, Req0),
    {ok, Body, Req} = cowboy_req:read_body(Req0),
    case IfMatch of
        ?ETAG ->
            _ = Body,
            cowboy_req:reply(204, #{}, <<>>, Req);
        _ ->
            cowboy_req:reply(
              412, #{<<"content-type">> => ?JSON},
              mgmtd_ems_json:encode(
                #{<<"ietf-restconf:errors">> =>
                      #{<<"error">> =>
                            [#{<<"error-tag">> => <<"operation-failed">>,
                               <<"error-message">> => <<"precondition failed">>}]}}),
              Req)
    end;
dispatch(<<"POST">>, <<"/restconf/data/ex:list">>, Req0) ->
    {ok, _Body, Req} = cowboy_req:read_body(Req0),
    cowboy_req:reply(201,
                     #{<<"content-type">> => ?JSON,
                       <<"location">> => <<"/restconf/data/ex:list=n1">>},
                     <<>>, Req);
dispatch(<<"PATCH">>, <<"/restconf/data/ex:foo">>, Req0) ->
    {ok, _Body, Req} = cowboy_req:read_body(Req0),
    cowboy_req:reply(204, #{}, <<>>, Req);
dispatch(_, _, Req) ->
    cowboy_req:reply(404, #{<<"content-type">> => ?JSON},
                     <<"{\"ietf-restconf:errors\":{\"error\":["
                       "{\"error-tag\":\"invalid-value\","
                       "\"error-message\":\"not found\"}]}}">>,
                     Req).
