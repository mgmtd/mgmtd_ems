%%%-------------------------------------------------------------------
%%% erlydtl northbound UI against a fake RESTCONF node.
%%%-------------------------------------------------------------------
-module(mgmtd_ems_ui_test).

-include_lib("eunit/include/eunit.hrl").

-export([init/2]).

-define(LISTENER, mgmtd_ems_ui_south_listener).
-define(LISTENER_PLAIN, mgmtd_ems_ui_south_plain).
-define(FIXTURE, mgmtd_ems_ui_test_fixture).
-define(JSON, <<"application/yang-data+json">>).
-define(YANG, <<"application/yang">>).
-define(XRD, <<"application/xrd+xml">>).
-define(YANG_A,
        <<"module example {\n  namespace \"urn:ex:a\";\n  prefix a;\n"
          "  container only-a { leaf x { type string; } }\n"
          "  container server {\n"
          "    list servers {\n"
          "      key name;\n"
          "      leaf name { type string; }\n"
          "      leaf host { type string; }\n"
          "      leaf port { type uint16; }\n"
          "    }\n"
          "  }\n}\n">>).
-define(YANG_RPC,
        <<"module example-rpc {\n  namespace \"urn:example:rpc\";\n  prefix rpc;\n"
          "  rpc echo {\n    description \"Echo a string.\";\n"
          "    input { leaf in { type string; description \"String to echo\"; } }\n"
          "    output { leaf out { type string; } }\n"
          "  }\n}\n">>).
-define(HOST_META,
        <<"<XRD xmlns='http://docs.oasis-open.org/ns/xri/xrd-1.0'>\n"
          "  <Link rel='restconf' href='/restconf'/>\n"
          "</XRD>\n">>).

ui_test_() ->
    {setup, fun setup/0, fun teardown/1,
     fun(#{ui := Ui, south := _South}) ->
             [{"inventory lists the node", fun() -> inventory(Ui) end},
              {"node page shows YANG tree", fun() -> node_page(Ui) end},
              {"config leaf shows save", fun() -> leaf_shows_save(Ui) end},
              {"save writes southbound", fun() -> save_leaf(Ui) end},
              {"save list item leaf", fun() -> save_list_item_leaf(Ui) end},
              {"add node from form", fun() -> add_from_form(Ui) end},
              {"add node validation keeps dialog", fun() -> add_missing_name(Ui) end},
              {"actions tab when schema has rpcs", fun() -> actions_tab(Ui) end},
              {"no actions tab without rpcs", fun() -> no_actions_tab(Ui) end},
              {"invoke echo rpc", fun() -> invoke_echo(Ui) end}]
     end}.

setup() ->
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, _} = application:ensure_all_started(inets),
    application:load(mgmtd_ems),
    application:set_env(mgmtd_ems, probe_interval, 0),
    application:unset_env(mgmtd_ems, nodes),
    application:set_env(mgmtd_ems, http,
                        [{enabled, true}, {port, 0}, {auth, false}]),
    stop_stack(),
    try ets:delete(?FIXTURE) catch error:badarg -> ok end,
    ets:new(?FIXTURE, [named_table, public, set]),
    ets:insert(?FIXTURE, {x, <<"hello">>}),
    ets:insert(?FIXTURE, {servers, [#{<<"name">> => <<"web">>,
                                     <<"host">> => <<"127.0.0.1">>,
                                     <<"port">> => 80}]}),
    DispatchRpc = cowboy_router:compile([{'_', [{'_', ?MODULE, rpc}]}]),
    DispatchPlain = cowboy_router:compile([{'_', [{'_', ?MODULE, no_rpc}]}]),
    {ok, _} = cowboy:start_clear(?LISTENER, [{port, 0}],
                                 #{env => #{dispatch => DispatchRpc}}),
    {ok, _} = cowboy:start_clear(?LISTENER_PLAIN, [{port, 0}],
                                 #{env => #{dispatch => DispatchPlain}}),
    South = ranch:get_port(?LISTENER),
    Plain = ranch:get_port(?LISTENER_PLAIN),
    {ok, Pid} = mgmtd_ems_sup:start_link(),
    unlink(Pid),
    ok = mgmtd_ems_http:start(),
    Ui = mgmtd_ems_http:port(),
    ok = mgmtd_ems:add_node(edge1, #{host => "127.0.0.1", port => South}),
    {ok, up} = mgmtd_ems:probe(edge1),
    ok = mgmtd_ems:add_node(plain1, #{host => "127.0.0.1", port => Plain}),
    {ok, up} = mgmtd_ems:probe(plain1),
    #{ui => Ui, south => South}.

teardown(_) ->
    mgmtd_ems_http:stop(),
    stop_stack(),
    _ = cowboy:stop_listener(?LISTENER),
    _ = cowboy:stop_listener(?LISTENER_PLAIN),
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
    ?assertNotEqual(nomatch, binary:match(Body, <<"mgmtd EMS">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"Add node">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"id=\"add-node\"">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"Remove">>)),
    ?assertEqual(nomatch, binary:match(Body, <<"Logout">>)).

node_page(Ui) ->
    {ok, 200, _, Body} = http_get(Ui, "/nodes/edge1"),
    ?assertNotEqual(nomatch, binary:match(Body, <<"only-a">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"example">>)),
    ?assertEqual(nomatch, binary:match(Body, <<"example-rpc:echo">>)).

leaf_shows_save(Ui) ->
    Path = "/restconf/data/example:only-a/x",
    {ok, 200, _, Body} = http_get(Ui, "/nodes/edge1?path=" ++ uri_encode_list(Path)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"Save">>)).

save_leaf(Ui) ->
    Path = "/restconf/data/example:only-a/x",
    Form = <<"path=", (uri_encode(Path))/binary,
             "&value=world&etag=&return=", (uri_encode(Path))/binary,
             "&view=index&mode=config">>,
    {ok, 303, Hdrs, _} = http_post(Ui, "/nodes/edge1/save", Form),
    Loc = header("location", Hdrs),
    ?assertEqual(true, is_list(Loc) andalso Loc =/= undefined),
    ?assertEqual(<<"world">>, ets:lookup_element(?FIXTURE, x, 2)).

save_list_item_leaf(Ui) ->
    List = "/restconf/data/example:server/servers",
    {ok, 200, _, Page} = http_get(Ui, "/nodes/edge1?path=" ++ uri_encode_list(List)),
    ?assertNotEqual(nomatch, binary:match(Page, <<"servers=web/host">>)),
    Path = "/restconf/data/example:server/servers=web/host",
    Form = <<"path=", (uri_encode(Path))/binary,
             "&value=10.0.0.1&etag=&return=", (uri_encode(List))/binary,
             "&view=index&mode=config">>,
    {ok, 303, _, _} = http_post(Ui, "/nodes/edge1/save", Form),
    [#{<<"host">> := Host}] = ets:lookup_element(?FIXTURE, servers, 2),
    ?assertEqual(<<"10.0.0.1">>, Host).

add_from_form(Ui) ->
    Form = <<"name=edge2&host=127.0.0.1&port=9">>,
    {ok, 303, _, _} = http_post(Ui, "/nodes", Form),
    {ok, Node} = mgmtd_ems:node(<<"edge2">>),
    ?assertEqual("127.0.0.1", maps:get(host, Node)).

add_missing_name(Ui) ->
    Form = <<"name=&host=127.0.0.1">>,
    {ok, 200, _, Body} = http_post(Ui, "/nodes", Form),
    ?assertNotEqual(nomatch, binary:match(Body, <<"name is required">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"id=\"add-node\"">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"showModal()">>)).

actions_tab(Ui) ->
    {ok, 200, _, Config} = http_get(Ui, "/nodes/edge1"),
    ?assertNotEqual(nomatch, binary:match(Config, <<"Actions">>)),
    ?assertNotEqual(nomatch, binary:match(Config, <<"mode=actions">>)),
    {ok, 200, _, Actions} = http_get(Ui, "/nodes/edge1?mode=actions"),
    ?assertNotEqual(nomatch, binary:match(Actions, <<"echo">>)),
    ?assertNotEqual(nomatch, binary:match(Actions, <<"operations">>)),
    ?assertNotEqual(nomatch, binary:match(Actions, <<"example-rpc">>)),
    ?assertEqual(nomatch, binary:match(Actions, <<"only-a">>)).

no_actions_tab(Ui) ->
    {ok, 200, _, Body} = http_get(Ui, "/nodes/plain1"),
    ?assertNotEqual(nomatch, binary:match(Body, <<"only-a">>)),
    ?assertEqual(nomatch, binary:match(Body, <<"Actions">>)).

invoke_echo(Ui) ->
    Path = "/restconf/operations/example-rpc:echo",
    Form = <<"path=", (uri_encode(Path))/binary,
             "&return=", (uri_encode(Path))/binary,
             "&view=index&mode=actions&input.in=hi">>,
    {ok, 200, _, Body} = http_post(Ui, "/nodes/edge1/rpc", Form),
    ?assertNotEqual(nomatch, binary:match(Body, <<"echo:hi">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"Output">>)).

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

uri_encode_list(S) ->
    binary_to_list(uri_encode(S)).

enc_byte($/) -> "%2F";
enc_byte($:) -> "%3A";
enc_byte($=) -> "%3D";
enc_byte(C) -> C.

init(Req0, State) ->
    {ok, dispatch(cowboy_req:method(Req0), cowboy_req:path(Req0), Req0, State), State}.

dispatch(<<"GET">>, <<"/.well-known/host-meta">>, Req, _State) ->
    cowboy_req:reply(200, #{<<"content-type">> => ?XRD}, ?HOST_META, Req);
dispatch(<<"GET">>, <<"/restconf/data/ietf-yang-library:modules-state">>, Req, no_rpc) ->
    Body = mgmtd_ems_json:encode(
             #{<<"ietf-yang-library:modules-state">> =>
                   #{<<"module-set-id">> => <<"set-plain">>,
                     <<"module">> => yanglib_example()}}),
    cowboy_req:reply(200, #{<<"content-type">> => ?JSON}, Body, Req);
dispatch(<<"GET">>, <<"/restconf/data/ietf-yang-library:modules-state">>, Req, _State) ->
    Body = mgmtd_ems_json:encode(
             #{<<"ietf-yang-library:modules-state">> =>
                   #{<<"module-set-id">> => <<"set-a">>,
                     <<"module">> => yanglib_example() ++ yanglib_rpc()}}),
    cowboy_req:reply(200, #{<<"content-type">> => ?JSON}, Body, Req);
dispatch(<<"GET">>, <<"/restconf/yang/example">>, Req, _State) ->
    cowboy_req:reply(200, #{<<"content-type">> => ?YANG}, ?YANG_A, Req);
dispatch(<<"GET">>, <<"/restconf/yang/example-rpc">>, Req, _State) ->
    cowboy_req:reply(200, #{<<"content-type">> => ?YANG}, ?YANG_RPC, Req);
dispatch(<<"GET">>, <<"/restconf/data/example:only-a/x">>, Req, _State) ->
    Val = ets:lookup_element(?FIXTURE, x, 2),
    Body = mgmtd_ems_json:encode(#{<<"example:x">> => Val}),
    cowboy_req:reply(200, #{<<"content-type">> => ?JSON, <<"etag">> => <<"\"v1\"">>},
                     Body, Req);
dispatch(<<"GET">>, <<"/restconf/data/example:only-a">>, Req, _State) ->
    Val = ets:lookup_element(?FIXTURE, x, 2),
    Body = mgmtd_ems_json:encode(
             #{<<"example:only-a">> => #{<<"x">> => Val}}),
    cowboy_req:reply(200, #{<<"content-type">> => ?JSON, <<"etag">> => <<"\"v1\"">>},
                     Body, Req);
dispatch(<<"GET">>, <<"/restconf/data/example:server/servers">>, Req, _State) ->
    Rows = ets:lookup_element(?FIXTURE, servers, 2),
    Body = mgmtd_ems_json:encode(#{<<"example:servers">> => Rows}),
    cowboy_req:reply(200, #{<<"content-type">> => ?JSON, <<"etag">> => <<"\"v1\"">>},
                     Body, Req);
dispatch(<<"POST">>, <<"/restconf/operations/example-rpc:echo">>, Req0, _State) ->
    {ok, Body, Req} = cowboy_req:read_body(Req0),
    In = case mgmtd_ems_json:decode(Body) of
             {ok, Map} ->
                 Input = maps:get(<<"example-rpc:input">>, Map,
                                  maps:get(<<"input">>, Map, #{})),
                 to_bin(maps:get(<<"in">>, Input, <<>>));
             {error, _} ->
                 <<>>
         end,
    Resp = mgmtd_ems_json:encode(
             #{<<"example-rpc:output">> => #{<<"out">> => <<"echo:", In/binary>>}}),
    cowboy_req:reply(200, #{<<"content-type">> => ?JSON}, Resp, Req);
dispatch(Method, <<"/restconf/data/example:only-a/x">>, Req0, _State)
  when Method =:= <<"PATCH">>; Method =:= <<"PUT">> ->
    {ok, Body, Req} = cowboy_req:read_body(Req0),
    {ok, Map} = mgmtd_ems_json:decode(Body),
    Val = maps:get(<<"example:x">>, Map, maps:get(<<"x">>, Map, <<>>)),
    ets:insert(?FIXTURE, {x, to_bin(Val)}),
    cowboy_req:reply(204, #{}, <<>>, Req);
dispatch(Method, <<"/restconf/data/example:server/servers=", Rest/binary>>, Req0, _State)
  when Method =:= <<"PATCH">>; Method =:= <<"PUT">> ->
    {ok, Body, Req} = cowboy_req:read_body(Req0),
    {ok, Map} = mgmtd_ems_json:decode(Body),
    case binary:split(Rest, <<"/">>) of
        [Name, Leaf] ->
            Val = maps:get(<<"example:", Leaf/binary>>, Map,
                           maps:get(Leaf, Map, <<>>)),
            update_server(Name, Leaf, Val),
            cowboy_req:reply(204, #{}, <<>>, Req);
        _ ->
            cowboy_req:reply(404, #{<<"content-type">> => ?JSON},
                             <<"{\"ietf-restconf:errors\":{\"error\":["
                               "{\"error-tag\":\"invalid-value\"}]}}">>,
                             Req)
    end;
dispatch(_, _, Req, _State) ->
    cowboy_req:reply(404, #{<<"content-type">> => ?JSON},
                     <<"{\"ietf-restconf:errors\":{\"error\":["
                       "{\"error-tag\":\"invalid-value\"}]}}">>,
                     Req).

yanglib_example() ->
    [#{<<"name">> => <<"example">>,
       <<"revision">> => <<>>,
       <<"namespace">> => <<"urn:ex:a">>,
       <<"conformance-type">> => <<"implement">>,
       <<"schema">> => <<"/restconf/yang/example">>}].

yanglib_rpc() ->
    [#{<<"name">> => <<"example-rpc">>,
       <<"revision">> => <<>>,
       <<"namespace">> => <<"urn:example:rpc">>,
       <<"conformance-type">> => <<"implement">>,
       <<"schema">> => <<"/restconf/yang/example-rpc">>}].

update_server(Name, Leaf, Val) ->
    Rows = ets:lookup_element(?FIXTURE, servers, 2),
    Updated =
        [case maps:get(<<"name">>, R) of
             Name -> R#{Leaf => to_bin(Val)};
             _ -> R
         end || R <- Rows],
    ets:insert(?FIXTURE, {servers, Updated}).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L).
