%%%-------------------------------------------------------------------
%% @doc `simple_one_for_one` supervisor for per-node session workers.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_ems_session_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

-define(SERVER, ?MODULE).
-define(TAB, mgmtd_ems_sessions).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    ets:new(?TAB, [named_table, public, set]),
    SupFlags = #{strategy => simple_one_for_one,
                 intensity => 10,
                 period => 60},
    Child = #{id => mgmtd_ems_session,
              start => {mgmtd_ems_session, start_link, []},
              restart => transient,
              shutdown => 5000,
              type => worker,
              modules => [mgmtd_ems_session]},
    {ok, {SupFlags, [Child]}}.
