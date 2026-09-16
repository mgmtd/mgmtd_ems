%%%-------------------------------------------------------------------
%% @doc mgmtd_ems application callback.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_ems_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    case mgmtd_ems_sup:start_link() of
        {ok, Pid} ->
            case mgmtd_ems_http:start() of
                ok ->
                    {ok, Pid};
                {error, Reason} ->
                    exit(Pid, shutdown),
                    {error, Reason}
            end;
        Other ->
            Other
    end.

stop(_State) ->
    mgmtd_ems_http:stop(),
    ok.
