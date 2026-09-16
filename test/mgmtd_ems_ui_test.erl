%%%-------------------------------------------------------------------
%%% erlydtl northbound UI against a fake RESTCONF node.
%%%-------------------------------------------------------------------
-module(mgmtd_ems_ui_test).

-include_lib("eunit/include/eunit.hrl").

-export([init/2]).

-define(LISTENER, mgmtd_ems_ui_south_listener).
-define(FIXTURE, mgmtd_ems_ui_test_fixture).
-define(JSON, <<"application/yang-data+json">>).
-define(YANG, <<"application/yang">>).
-define(XRD, <<"application/xrd+xml">>).
-define(YANG_A,
        <<"module example {\n  namespace \"urn:ex:a\";\n  prefix a;\n"
          "  container only-a { leaf x { type string; } }\n}\n">>).
-define(HOST_META,
        <<"<XRD xmlns='http://docs.oasis-open.org/ns/xri/xrd-1.0'>\n"
          "  <Link rel='restconf' href='/restconf'/>\n"
          "</XRD>\n">>).

ui_test_() ->
    {setup, fun setup/0, fun teardown/1,
     fun(#{ui := Ui, south := _South}) ->
             [{"inventory lists the node", fun() -> inventory(Ui) end},
              {"node page shows YANG tree", fun() -> node_page(Ui) end},
              {"save writes southbound", fun() -> save_leaf(Ui) end},
              {"add node from form", fun() -> add_from_form(Ui) end}]
     end}.

setup() ->
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, _} = application:ensure_all_started(inets),
    application:load(mgmtd_ems),
    application:set_env(mgmtd_ems, probe_interval, 0),
    application:unset_env(mgmtd_ems, nodes),
    application:set_env(mgmtd_ems, http, [{enabled, true}, {port, 0}]),
    stop_stack(),
    try ets:delete(?FIXTURE) catch error:badarg -> ok end,
    ets:new(?FIXTURE, [named_table, public, set]),
    ets:insert(?FIXTURE, {x, <<"hello">>}),
    Dispatch = cowboy_router:compile([{'_', [{'_', ?MODULE, []}]}]),
    {ok, _} = cowboy:start_clear(?LISTENER, [{port, 0}],
                                 #{env => #{dispatch => Dispatch}}),
    South = ranch:get_port(?LISTENER),
    {ok, Pid} = mgmtd_ems_sup:start_link(),
    unlink(Pid),
    ok = mgmtd_ems_http:start(),
    Ui = mgmtd_ems_http:port(),
    ok = mgmtd_ems:add_node(edge1, #{host => "127.0.0.1", port => South}),
    {ok, up} = mgmtd_ems:probe(edge1),
    #{ui => Ui, south => South}.

teardown(_) ->
    mgmtd_ems_http:stop(),
    stop_stack(),
    _ = cowboy:stop_listener(?LISTENER),
    try ets:delete(?FIXTURE) catch error:badarg -> ok end,
    application:unset_env(mgmtd_ems, http),
    application:unset_env(mgmtd_ems, probe_interval),
    ok.

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
                  undefined -> ok;
                  P -> unlink(P), try gen_server:stop(P) catch _:_ -> ok end
              end
      end,
      [mgmtd_ems_sessions, mgmtd_ems_session_sup,
       mgmtd_ems_schema, mgmtd_ems_inventory]).

inventory(Ui) ->
    {ok, 200, _, Body} = http_get(Ui, "/"),
    ?assertNotEqual(nomatch, binary:match(Body, <<"edge1">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"mgmtd EMS">>)).

node_page(Ui) ->
    {ok, 200, _, Body} = http_get(Ui, "/nodes/edge1"),
    ?assertNotEqual(nomatch, binary:match(Body, <<"only-a">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"example">>)).

save_leaf(Ui) ->
    Path = "/restconf/data/example:only-a/x",
    Form = <<"path=", (uri_encode(Path))/binary,
             "&value=world&etag=&return=", (uri_encode(Path))/binary,
             "&view=index&mode=config">>,
    {ok, 303, Hdrs, _} = http_post(Ui, "/nodes/edge1/save", Form),
    Loc = header("location", Hdrs),
    ?assertEqual(true, is_list(Loc) andalso Loc =/= undefined),
    ?assertEqual(<<"world">>, ets:lookup_element(?FIXTURE, x, 2)).

add_from_form(Ui) ->
    Form = <<"name=edge2&host=127.0.0.1&port=9">>,
    {ok, 303, _, _} = http_post(Ui, "/nodes", Form),
    {ok, Node} = mgmtd_ems:node(<<"edge2">>),
    ?assertEqual("127.0.0.1", maps:get(host, Node)).

http_get(Port, Path) ->
    Url = "http://127.0.0.1:" ++ integer_to_list(Port) ++ Path,
    case httpc:request(get, {Url, []}, [{timeout, 5000}], [{body_format, binary}]) of
        {ok, {{_, Status, _}, Hdrs, Body}} ->
            {ok, Status, Hdrs, iolist_to_binary(Body)};
        {error, Reason} ->
            {error, Reason}
    end.

http_post(Port, Path, Body) ->
    Url = "http://127.0.0.1:" ++ integer_to_list(Port) ++ Path,
    Hdrs = [{"content-type", "application/x-www-form-urlencoded"}],
    case httpc:request(post, {Url, Hdrs, "application/x-www-form-urlencoded", Body},
                       [{timeout, 5000}, {autoredirect, false}],
                       [{body_format, binary}]) of
        {ok, {{_, Status, _}, RespHdrs, RespBody}} ->
            {ok, Status, RespHdrs, iolist_to_binary(RespBody)};
        {error, Reason} ->
            {error, Reason}
    end.

header(Name, Hdrs) ->
    Want = string:lowercase(Name),
    case lists:dropwhile(fun({K, _}) -> string:lowercase(K) =/= Want end, Hdrs) of
        [{_, V} | _] -> V;
        [] -> undefined
    end.

uri_encode(S) ->
    list_to_binary([enc_byte(C) || C <- S]).

enc_byte($/) -> "%2F";
enc_byte($:) -> "%3A";
enc_byte(C) -> C.

init(Req0, State) ->
    {ok, dispatch(cowboy_req:method(Req0), cowboy_req:path(Req0), Req0), State}.

dispatch(<<"GET">>, <<"/.well-known/host-meta">>, Req) ->
    cowboy_req:reply(200, #{<<"content-type">> => ?XRD}, ?HOST_META, Req);
dispatch(<<"GET">>, <<"/restconf/data/ietf-yang-library:modules-state">>, Req) ->
    Body = mgmtd_ems_json:encode(
             #{<<"ietf-yang-library:modules-state">> =>
                   #{<<"module-set-id">> => <<"set-a">>,
                     <<"module">> =>
                         [#{<<"name">> => <<"example">>,
                            <<"revision">> => <<>>,
                            <<"namespace">> => <<"urn:ex:a">>,
                            <<"conformance-type">> => <<"implement">>,
                            <<"schema">> => <<"/restconf/yang/example">>}]}}),
    cowboy_req:reply(200, #{<<"content-type">> => ?JSON}, Body, Req);
dispatch(<<"GET">>, <<"/restconf/yang/example">>, Req) ->
    cowboy_req:reply(200, #{<<"content-type">> => ?YANG}, ?YANG_A, Req);
dispatch(<<"GET">>, <<"/restconf/data/example:only-a/x">>, Req) ->
    Val = ets:lookup_element(?FIXTURE, x, 2),
    Body = mgmtd_ems_json:encode(#{<<"example:x">> => Val}),
    cowboy_req:reply(200, #{<<"content-type">> => ?JSON, <<"etag">> => <<"\"v1\"">>},
                     Body, Req);
dispatch(<<"GET">>, <<"/restconf/data/example:only-a">>, Req) ->
    Val = ets:lookup_element(?FIXTURE, x, 2),
    Body = mgmtd_ems_json:encode(
             #{<<"example:only-a">> => #{<<"x">> => Val}}),
    cowboy_req:reply(200, #{<<"content-type">> => ?JSON, <<"etag">> => <<"\"v1\"">>},
                     Body, Req);
dispatch(Method, <<"/restconf/data/example:only-a/x">>, Req0)
  when Method =:= <<"PATCH">>; Method =:= <<"PUT">> ->
    {ok, Body, Req} = cowboy_req:read_body(Req0),
    {ok, Map} = mgmtd_ems_json:decode(Body),
    Val = maps:get(<<"example:x">>, Map, maps:get(<<"x">>, Map, <<>>)),
    ets:insert(?FIXTURE, {x, to_bin(Val)}),
    cowboy_req:reply(204, #{}, <<>>, Req);
dispatch(_, _, Req) ->
    cowboy_req:reply(404, #{<<"content-type">> => ?JSON},
                     <<"{\"ietf-restconf:errors\":{\"error\":["
                       "{\"error-tag\":\"invalid-value\"}]}}">>,
                     Req).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L).
