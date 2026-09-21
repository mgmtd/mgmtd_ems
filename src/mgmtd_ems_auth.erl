%%%-------------------------------------------------------------------
%%% @doc Pluggable HTTP authentication for the EMS web UI.
%%%
%%% Cowboy middleware, run *before* `cowboy_router` so a callback can
%%% own login/callback/logout paths (OIDC) without UI dispatch entries.
%%%
%%% Callback module:
%%%
%%%     -callback init(Opts) -> {ok, State} | {error, term()}.
%%%     -callback authenticate(Req, State) ->
%%%         {ok, Identity, Req} | {stop, Req}.
%%%     -callback terminate(State) -> ok.   %% optional
%%%
%%% `{ok, Identity, Req}` continues to the router. `{stop, Req}` means
%%% the callback already replied (login page, 302 to an IdP, logout, …).
%%% Modules own `/login` and `/logout`.
%%%
%%% `Identity` is `#{user := binary(), role => admin | read_only, ...}`.
%%% Missing `role` is treated as `admin`. After a successful
%%% authenticate, GET/HEAD/OPTIONS are `read`; everything else is
%%% `write` (`read_only` → 403).
%%%
%%% sys.config (`mgmtd_ems` `http`):
%%%
%%%     {auth, [{module, mgmtd_ems_auth_basic},
%%%             {users, [{"alice", "secret"},
%%%                      {"bob", "guest", read_only}]}]}
%%%
%%% Omitted / empty `auth` uses `mgmtd_ems_auth_basic` with no users
%%% (login form; nobody can sign in). `{auth, false}` is
%%% `mgmtd_ems_auth_none` (open).
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_ems_auth).

-behaviour(cowboy_middleware).

-export([init/0, terminate/1, execute/2, identity/1]).

-export_type([opts/0, identity/0, cb/0]).

-type opts() :: proplists:proplist().
-type identity() :: #{user := binary(),
                      role => admin | read_only,
                      atom() => term()}.
-type cb() :: #{module := module(), state := term()}.

-callback init(opts()) -> {ok, term()} | {error, term()}.
-callback authenticate(cowboy_req:req(), term()) ->
    {ok, identity(), cowboy_req:req()} | {stop, cowboy_req:req()}.
-callback terminate(term()) -> ok.

-optional_callbacks([terminate/1]).

-spec init() -> {ok, cb()} | {error, term()}.
init() ->
    _ = application:ensure_all_started(crypto),
    {Mod, Opts} = resolve(),
    case Mod:init(Opts) of
        {ok, State} ->
            {ok, #{module => Mod, state => State}};
        {error, _} = Err ->
            Err
    end.

-spec terminate(cb() | undefined) -> ok.
terminate(#{module := Mod, state := State}) ->
    case erlang:function_exported(Mod, terminate, 1) of
        true ->
            _ = Mod:terminate(State),
            ok;
        false ->
            ok
    end;
terminate(_) ->
    ok.

-spec execute(cowboy_req:req(), cowboy_middleware:env()) ->
          {ok, cowboy_req:req(), cowboy_middleware:env()} |
          {stop, cowboy_req:req()}.
execute(Req, Env) ->
    #{module := Mod, state := State} = maps:get(auth_cb, Env),
    case Mod:authenticate(Req, State) of
        {ok, Identity, Req1} when is_map(Identity) ->
            case permits(Identity, cowboy_req:method(Req1)) of
                true ->
                    {ok, Req1#{auth => Identity}, Env#{auth => Identity}};
                false ->
                    {stop, forbidden(Req1)}
            end;
        {stop, Req1} ->
            {stop, Req1}
    end.

-spec identity(cowboy_req:req()) -> identity() | undefined.
identity(Req) ->
    maps:get(auth, Req, undefined).

%%--------------------------------------------------------------------
%% Config
%%--------------------------------------------------------------------

resolve() ->
    case auth_config() of
        false ->
            {mgmtd_ems_auth_none, []};
        List when is_list(List) ->
            Mod = proplists:get_value(module, List, mgmtd_ems_auth_basic),
            {Mod, proplists:delete(module, List)};
        _ ->
            {mgmtd_ems_auth_basic, []}
    end.

auth_config() ->
    case application:get_env(mgmtd_ems, http, []) of
        List when is_list(List) ->
            proplists:get_value(auth, List, []);
        _ ->
            []
    end.

%%--------------------------------------------------------------------
%% Role check
%%--------------------------------------------------------------------

permits(Identity, Method) ->
    Role = maps:get(role, Identity, admin),
    access_ok(Role, access_for(Method)).

access_for(<<"GET">>) -> read;
access_for(<<"HEAD">>) -> read;
access_for(<<"OPTIONS">>) -> read;
access_for(_) -> write.

access_ok(read_only, write) ->
    false;
access_ok(read_only, read) ->
    true;
access_ok(_, _) ->
    true.

forbidden(Req) ->
    cowboy_req:reply(
      403,
      #{<<"content-type">> => <<"text/plain; charset=utf-8">>},
      <<"permission denied">>,
      Req).
