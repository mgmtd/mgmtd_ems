%%%-------------------------------------------------------------------
%%% EMS web-UI HTTP auth (login form, session cookie, pluggable callback).
%%%-------------------------------------------------------------------
-module(mgmtd_ems_auth_test).

-include_lib("eunit/include/eunit.hrl").

%% Dummy OIDC-shaped callback (redirect + cookie session).
-export([init/1, authenticate/2]).

-define(USERS,
        [{users, [{"alice", "secret"},
                  {"bob", "guest", read_only}]}]).

auth_test_() ->
    [{setup, fun setup_default/0, fun teardown/1,
      fun default_cases/1},
     {setup, fun setup_none/0, fun teardown/1,
      fun none_cases/1},
     {setup, fun setup_users/0, fun teardown/1,
      fun user_cases/1},
     {setup, fun setup_dummy/0, fun teardown/1,
      fun dummy_cases/1}].

%%--------------------------------------------------------------------
%% Default (no auth key) — login form, nobody can sign in
%%--------------------------------------------------------------------

setup_default() ->
    start_http([]).

default_cases(Port) ->
    [{"omitted auth redirects to login",
      fun() ->
              {Code, Headers, _} = http_get(Port, "/", []),
              ?assertEqual(302, Code),
              Loc = proplists:get_value("location", Headers),
              ?assertEqual(true, is_login_redirect(Loc))
      end},
     {"login form is served",
      fun() ->
              {Code, _, Body} = http_get(Port, "/login", []),
              ?assertEqual(200, Code),
              ?assertNotEqual(nomatch, binary:match(Body, <<"name=\"user\"">>)),
              ?assertNotEqual(nomatch, binary:match(Body, <<"name=\"password\"">>))
      end}].

%%--------------------------------------------------------------------
%% {auth, false} — open
%%--------------------------------------------------------------------

setup_none() ->
    start_http([{auth, false}]).

none_cases(Port) ->
    [{"auth false serves inventory without logout",
      fun() ->
              {Code, Headers, Body} = http_get(Port, "/", []),
              ?assertEqual(200, Code),
              ?assertEqual(undefined,
                           proplists:get_value("www-authenticate", Headers)),
              ?assertNotEqual(nomatch, binary:match(Body, <<"mgmtd EMS">>)),
              ?assertEqual(nomatch, binary:match(Body, <<"Logout">>))
      end}].

%%--------------------------------------------------------------------
%% Form login + session
%%--------------------------------------------------------------------

setup_users() ->
    start_http([{auth, ?USERS}]).

user_cases(Port) ->
    [{"missing session redirects to login",
      fun() -> missing_session(Port) end},
     {"login form GET",
      fun() -> login_form(Port) end},
     {"bad password stays on form",
      fun() -> bad_password(Port) end},
     {"unknown user stays on form",
      fun() -> unknown_user(Port) end},
     {"admin can read UI and static",
      fun() -> admin_read(Port) end},
     {"read_only can GET and not POST",
      fun() -> read_only_cannot_write(Port) end},
     {"read_only inventory hides write controls",
      fun() -> read_only_hides_write_controls(Port) end},
     {"read_only hides actions tab",
      fun() -> read_only_hides_actions_tab(Port) end},
     {"admin inventory shows write controls",
      fun() -> admin_shows_write_controls(Port) end},
     {"admin shows actions tab in actions mode",
      fun() -> admin_shows_actions_tab(Port) end},
     {"inventory shows logout",
      fun() -> inventory_shows_logout(Port) end},
     {"logout clears session",
      fun() -> logout_clears(Port) end}].

missing_session(Port) ->
    {Code, Headers, _} = http_get(Port, "/", []),
    ?assertEqual(302, Code),
    ?assertEqual(true, is_login_redirect(proplists:get_value("location", Headers))),
    {CssCode, _, _} = http_get(Port, "/static/ems_ui.css", []),
    ?assertEqual(200, CssCode).

login_form(Port) ->
    {Code, _, Body} = http_get(Port, "/login", []),
    ?assertEqual(200, Code),
    ?assertNotEqual(nomatch, binary:match(Body, <<"Log in">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"name=\"user\"">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"name=\"password\"">>)).

bad_password(Port) ->
    {Code, _, Body} = post_login(Port, "alice", "wrong"),
    ?assertEqual(200, Code),
    ?assertNotEqual(nomatch, binary:match(Body, <<"Invalid username or password">>)).

unknown_user(Port) ->
    {Code, _, Body} = post_login(Port, "eve", "secret"),
    ?assertEqual(200, Code),
    ?assertNotEqual(nomatch, binary:match(Body, <<"Invalid username or password">>)).

admin_read(Port) ->
    Cookie = login_cookie(Port, "alice", "secret"),
    {Code, _, Body} = http_get(Port, "/", [Cookie]),
    ?assertEqual(200, Code),
    ?assertNotEqual(nomatch, binary:match(Body, <<"mgmtd EMS">>)),
    {CssCode, _, _} = http_get(Port, "/static/ems_ui.css", []),
    ?assertEqual(200, CssCode).

inventory_shows_logout(Port) ->
    Cookie = login_cookie(Port, "alice", "secret"),
    {Code, _, Body} = http_get(Port, "/", [Cookie]),
    ?assertEqual(200, Code),
    ?assertNotEqual(nomatch, binary:match(Body, <<"Logout">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"href=\"/logout\"">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"alice">>)).

logout_clears(Port) ->
    Cookie = login_cookie(Port, "alice", "secret"),
    {Code, Headers, _} = http_get(Port, "/logout", [Cookie]),
    ?assertEqual(302, Code),
    ?assertEqual("/login", proplists:get_value("location", Headers)),
    {Blocked, LocHdrs, _} = http_get(Port, "/", [Cookie]),
    ?assertEqual(302, Blocked),
    ?assertEqual(true, is_login_redirect(proplists:get_value("location", LocHdrs))).

read_only_cannot_write(Port) ->
    Cookie = login_cookie(Port, "bob", "guest"),
    {GetCode, _, _} = http_get(Port, "/", [Cookie]),
    ?assertEqual(200, GetCode),
    {OptCode, _, _} = http_req(options, Port, "/", [Cookie], <<>>),
    ?assertEqual(200, OptCode),
    {PostCode, _, Body} =
        http_req(post, Port, "/nodes", [Cookie],
                 <<"name=x&host=127.0.0.1">>),
    ?assertEqual(403, PostCode),
    ?assertEqual(<<"permission denied">>, Body).

read_only_hides_write_controls(Port) ->
    ok = ensure_inventory_node(),
    Cookie = login_cookie(Port, "bob", "guest"),
    {Code, _, Body} = http_get(Port, "/", [Cookie]),
    ?assertEqual(200, Code),
    ?assertNotEqual(nomatch, binary:match(Body, <<"edge1">>)),
    ?assertEqual(nomatch, binary:match(Body, <<"Add node">>)),
    ?assertEqual(nomatch, binary:match(Body, <<"Remove">>)).

read_only_hides_actions_tab(Port) ->
    ok = ensure_inventory_node(),
    Cookie = login_cookie(Port, "bob", "guest"),
    {Code, _, Body} = http_get(Port, "/nodes/edge1?mode=actions", [Cookie]),
    ?assertEqual(200, Code),
    ?assertEqual(nomatch, binary:match(Body, <<"title=\"RPC actions\"">>)).

admin_shows_actions_tab(Port) ->
    ok = ensure_inventory_node(),
    Cookie = login_cookie(Port, "alice", "secret"),
    {Code, _, Body} = http_get(Port, "/nodes/edge1?mode=actions", [Cookie]),
    ?assertEqual(200, Code),
    ?assertNotEqual(nomatch, binary:match(Body, <<"title=\"RPC actions\"">>)).

admin_shows_write_controls(Port) ->
    ok = ensure_inventory_node(),
    Cookie = login_cookie(Port, "alice", "secret"),
    {Code, _, Body} = http_get(Port, "/", [Cookie]),
    ?assertEqual(200, Code),
    ?assertNotEqual(nomatch, binary:match(Body, <<"edge1">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"Add node">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"Remove">>)).

ensure_inventory_node() ->
    case mgmtd_ems_inventory:lookup(<<"edge1">>) of
        {ok, _} ->
            ok;
        {error, not_found} ->
            mgmtd_ems_inventory:add(<<"edge1">>, #{host => "127.0.0.1", port => 9})
    end.

%%--------------------------------------------------------------------
%% Dummy callback: 302 + cookie, like a future OIDC module
%%--------------------------------------------------------------------

setup_dummy() ->
    start_http([{auth, [{module, ?MODULE}]}]).

dummy_cases(Port) ->
    [{"unauthenticated UI redirects to IdP",
      fun() ->
              {Code, Headers, _} = http_get(Port, "/", []),
              ?assertEqual(302, Code),
              ?assertEqual("/idp",
                           proplists:get_value("location", Headers))
      end},
     {"callback sets cookie and redirects home",
      fun() ->
              {Code, Headers, _} = http_get(Port, "/oauth/callback", []),
              ?assertEqual(302, Code),
              ?assertEqual("/", proplists:get_value("location", Headers)),
              SetCookie = proplists:get_value("set-cookie", Headers),
              ?assert(is_list(SetCookie) andalso SetCookie =/= undefined),
              ?assertNotEqual(nomatch, string:find(SetCookie, "ems_sid=tok"))
      end},
     {"cookie session can read UI",
      fun() ->
              {Code, _, Body} =
                  http_get(Port, "/", [{"cookie", "ems_sid=tok"}]),
              ?assertEqual(200, Code),
              ?assertNotEqual(nomatch, binary:match(Body, <<"mgmtd EMS">>)),
              ?assertNotEqual(nomatch, binary:match(Body, <<"Logout">>))
      end},
     {"logout clears session cookie",
      fun() ->
              {Code, Headers, _} =
                  http_get(Port, "/logout", [{"cookie", "ems_sid=tok"}]),
              ?assertEqual(302, Code),
              ?assertEqual("/idp", proplists:get_value("location", Headers)),
              SetCookie = proplists:get_value("set-cookie", Headers),
              ?assert(is_list(SetCookie) andalso SetCookie =/= undefined),
              ?assertNotEqual(nomatch, string:find(string:lowercase(SetCookie),
                                                   "ems_sid="))
      end}].

init(_Opts) ->
    {ok, []}.

authenticate(Req, _State) ->
    case cowboy_req:path(Req) of
        <<"/oauth/callback">> ->
            Req1 = cowboy_req:set_resp_cookie(
                     <<"ems_sid">>, <<"tok">>, Req, #{path => <<"/">>}),
            {stop, cowboy_req:reply(302, #{<<"location">> => <<"/">>}, <<>>, Req1)};
        <<"/logout">> ->
            Req1 = cowboy_req:set_resp_cookie(
                     <<"ems_sid">>, <<>>, Req,
                     #{path => <<"/">>, max_age => 0}),
            {stop, cowboy_req:reply(302, #{<<"location">> => <<"/idp">>}, <<>>, Req1)};
        _ ->
            case lists:keyfind(<<"ems_sid">>, 1, cowboy_req:parse_cookies(Req)) of
                {_, <<"tok">>} ->
                    {ok, #{user => <<"oidc-user">>, role => admin}, Req};
                _ ->
                    {stop, cowboy_req:reply(
                             302, #{<<"location">> => <<"/idp">>}, <<>>, Req)}
            end
    end.

%%--------------------------------------------------------------------
%% HTTP / lifecycle
%%--------------------------------------------------------------------

start_http(AuthOpts) ->
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, _} = application:ensure_all_started(inets),
    application:load(mgmtd_ems),
    application:set_env(mgmtd_ems, http,
                        [{enabled, true}, {port, 0} | AuthOpts]),
    stop_http(),
    ok = start_inventory(),
    ok = mgmtd_ems_http:start(),
    mgmtd_ems_http:port().

teardown(_Port) ->
    stop_http(),
    stop_inventory(),
    application:unset_env(mgmtd_ems, http),
    ok.

start_inventory() ->
    stop_inventory(),
    {ok, Pid} = mgmtd_ems_inventory:start_link(),
    unlink(Pid),
    ok.

stop_inventory() ->
    case whereis(mgmtd_ems_inventory) of
        undefined ->
            ok;
        Pid ->
            unlink(Pid),
            try gen_server:stop(Pid) catch _:_ -> ok end,
            ok
    end.

stop_http() ->
    ok = mgmtd_ems_http:stop().

http_get(Port, Path, ExtraHdrs) ->
    http_req(get, Port, Path, ExtraHdrs, <<>>).

post_login(Port, User, Pass) ->
    Body = iolist_to_binary(
             io_lib:format("user=~s&password=~s", [User, Pass])),
    http_req(post, Port, "/login", [], Body).

login_cookie(Port, User, Pass) ->
    {Code, Headers, _} = post_login(Port, User, Pass),
    ?assertEqual(302, Code),
    ?assertEqual("/", proplists:get_value("location", Headers)),
    sid_cookie(Headers).

sid_cookie(Headers) ->
    Raw = proplists:get_value("set-cookie", Headers),
    case re:run(Raw, "ems_sid=([0-9A-Fa-f]+)", [{capture, all_but_first, list}]) of
        {match, [Sid]} ->
            {"cookie", "ems_sid=" ++ Sid};
        _ ->
            error({no_sid, Raw})
    end.

is_login_redirect(Loc) when is_list(Loc) ->
    lists:prefix("/login", Loc);
is_login_redirect(_) ->
    false.

http_req(Method, Port, Path, ExtraHdrs, Body)
  when Method =:= post; Method =:= put; Method =:= patch ->
    Url = url(Port, Path),
    {ok, {{_, Code, _}, Headers, Resp}} =
        httpc:request(Method,
                      {Url, ExtraHdrs, "application/x-www-form-urlencoded", Body},
                      [{timeout, 2000}, {autoredirect, false}],
                      [{body_format, binary}]),
    {Code, Headers, iolist_to_binary(Resp)};
http_req(Method, Port, Path, ExtraHdrs, _) ->
    Url = url(Port, Path),
    {ok, {{_, Code, _}, Headers, Resp}} =
        httpc:request(Method, {Url, ExtraHdrs},
                      [{timeout, 2000}, {autoredirect, false}],
                      [{body_format, binary}]),
    {Code, Headers, iolist_to_binary(Resp)}.

url(Port, Path) ->
    lists:flatten(io_lib:format("http://127.0.0.1:~p~s", [Port, Path])).
