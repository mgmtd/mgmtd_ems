%%%-------------------------------------------------------------------
%%% @doc Explicit open auth module for tests and local experiments.
%%%
%%% `{auth, false}` in `http` env is sugar for this module. Production
%%% configs should not use it.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_ems_auth_none).

-export([init/1, authenticate/2]).

-spec init(mgmtd_ems_auth:opts()) -> {ok, term()}.
init(_Opts) ->
    {ok, []}.

-spec authenticate(cowboy_req:req(), term()) ->
          {ok, mgmtd_ems_auth:identity(), cowboy_req:req()} |
          {stop, cowboy_req:req()}.
authenticate(Req, _State) ->
    case cowboy_req:path(Req) of
        <<"/logout">> ->
            {stop, cowboy_req:reply(302, #{<<"location">> => <<"/">>}, <<>>, Req)};
        <<"/logout/">> ->
            {stop, cowboy_req:reply(302, #{<<"location">> => <<"/">>}, <<>>, Req)};
        _ ->
            {ok, #{user => <<"anonymous">>, role => admin}, Req}
    end.
