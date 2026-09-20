%%%-------------------------------------------------------------------
%% @doc mgmtd_ems application callback.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_ems_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    case mgmtd_ems_cfg:load() of
        ok ->
            start_sup();
        {error, _} = Err ->
            Err
    end.

stop(_State) ->
    mgmtd_ems_cli:close(),
    mgmtd_ems_http:stop(),
    ok.

start_sup() ->
    case mgmtd_ems_sup:start_link() of
        {ok, Pid} ->
            ok = mgmtd_ems_inventory:bind_config(),
            case start_northbound() of
                ok ->
                    {ok, Pid};
                {error, Reason} ->
                    exit(Pid, shutdown),
                    {error, Reason}
            end;
        Other ->
            Other
    end.

start_northbound() ->
    case mgmtd_ems_cli:open() of
        ok ->
            mgmtd_ems_http:start();
        {error, _} = Err ->
            Err
    end.
