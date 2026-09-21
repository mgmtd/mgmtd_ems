%%%-------------------------------------------------------------------
%% @doc Northbound Cowboy listener for the erlydtl EMS UI.
%%
%% sys.config (`mgmtd_ems`):
%%
%%     {http, [{enabled, true}, {port, 8080},
%%             {auth, [{users, [{"alice", "secret"}]}]}]}
%%
%% `enabled` defaults to true when this module's `start/0` is called
%% (from the application callback, not from the supervisor used in tests).
%%
%% HTTP auth is pluggable (`mgmtd_ems_auth`). Default is a login form
%% against static users; omitted / empty `auth` still requires login
%% (nobody can sign in). `{auth, false}` opens the UI (tests only).
%% See `mgmtd_ems_auth`.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_ems_http).

-include("mgmtd_ems.hrl").

-export([start/0, stop/0, port/0, enabled/0]).

-define(LISTENER, mgmtd_ems_http).

-spec enabled() -> boolean().
enabled() ->
    proplists:get_value(enabled, config(), true).

-spec start() -> ok | {error, term()}.
start() ->
    case enabled() of
        false ->
            ok;
        true ->
            start_listener()
    end.

-spec stop() -> ok.
stop() ->
    AuthCb = auth_cb(),
    try cowboy:stop_listener(?LISTENER) of
        ok ->
            ok;
        {error, not_found} ->
            ok
    catch
        _:_ ->
            ok
    end,
    mgmtd_ems_auth:terminate(AuthCb).

-spec port() -> inet:port_number().
port() ->
    ranch:get_port(?LISTENER).

start_listener() ->
    {ok, _} = application:ensure_all_started(cowboy),
    ok = mgmtd_ems_ui:compile(),
    case mgmtd_ems_auth:init() of
        {ok, AuthCb} ->
            listen(AuthCb);
        {error, Reason} ->
            {error, Reason}
    end.

listen(AuthCb) ->
    Dispatch = cowboy_router:compile([{'_', routes()}]),
    TransOpts = [{port, listen_port()}],
    ProtoOpts = #{env => #{dispatch => Dispatch, auth_cb => AuthCb},
                  middlewares => [mgmtd_ems_auth, cowboy_router, cowboy_handler]},
    case cowboy:start_clear(?LISTENER, TransOpts, ProtoOpts) of
        {ok, _} ->
            ok;
        {error, {already_started, _}} ->
            _ = mgmtd_ems_auth:terminate(AuthCb),
            ok;
        {error, Reason} ->
            _ = mgmtd_ems_auth:terminate(AuthCb),
            {error, Reason}
    end.

auth_cb() ->
    try cowboy:get_env(?LISTENER, auth_cb, undefined) of
        Value ->
            Value
    catch
        _:_ ->
            undefined
    end.

routes() ->
    [{"/static/[...]", cowboy_static, {priv_dir, mgmtd_ems, "ui"}},
     {"/nodes/:name/content", mgmtd_ems_ui_handler, content},
     {"/nodes/:name/content/", mgmtd_ems_ui_handler, content},
     {"/nodes/:name/save", mgmtd_ems_ui_handler, save},
     {"/nodes/:name/add", mgmtd_ems_ui_handler, add},
     {"/nodes/:name/delete", mgmtd_ems_ui_handler, delete},
     {"/nodes/:name/rpc", mgmtd_ems_ui_handler, rpc},
     {"/nodes/:name/remove", mgmtd_ems_ui_handler, remove_node},
     {"/nodes/:name", mgmtd_ems_ui_handler, node},
     {"/nodes/:name/", mgmtd_ems_ui_handler, node},
     {"/nodes", mgmtd_ems_ui_handler, add_node},
     {"/nodes/", mgmtd_ems_ui_handler, add_node},
     {"/", mgmtd_ems_ui_handler, inventory}].

listen_port() ->
    proplists:get_value(port, config(), ?MGMTD_EMS_DEFAULT_HTTP_PORT).

config() ->
    case application:get_env(mgmtd_ems, http, []) of
        true ->
            [{enabled, true}];
        false ->
            [{enabled, false}];
        List when is_list(List) ->
            List
    end.
