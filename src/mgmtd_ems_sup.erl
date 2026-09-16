%%%-------------------------------------------------------------------
%% @doc mgmtd_ems top-level supervisor.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_ems_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    SupFlags =
        #{strategy => rest_for_one,
          intensity => 10,
          period => 60},
    Inventory =
        #{id => mgmtd_ems_inventory,
          start => {mgmtd_ems_inventory, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [mgmtd_ems_inventory]},
    Schema =
        #{id => mgmtd_ems_schema,
          start => {mgmtd_ems_schema, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [mgmtd_ems_schema]},
    SessionSup =
        #{id => mgmtd_ems_session_sup,
          start => {mgmtd_ems_session_sup, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => supervisor,
          modules => [mgmtd_ems_session_sup]},
    Sessions =
        #{id => mgmtd_ems_sessions,
          start => {mgmtd_ems_sessions, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [mgmtd_ems_sessions]},
    {ok, {SupFlags, [Inventory, Schema, SessionSup, Sessions]}}.
