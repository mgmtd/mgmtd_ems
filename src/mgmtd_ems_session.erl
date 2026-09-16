%%%-------------------------------------------------------------------
%% @doc Per-node probe worker.
%%
%% On start, and on `probe_interval` (default 30s), discover RESTCONF
%% and sync the YANG cache. Inventory `status` is `up`, `down`, or
%% `auth_error`. A down node keeps its last schema cache.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_ems_session).

-behaviour(gen_server).

-include("mgmtd_ems.hrl").

-export([start_link/1, run/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(TAB, mgmtd_ems_sessions).

-spec start_link(term()) -> {ok, pid()} | {error, term()}.
start_link(Name) ->
    gen_server:start_link(?MODULE, Name, []).

%% One-shot probe used by the worker and by `mgmtd_ems:probe/1`.
-spec run(term()) -> up | down | auth_error | not_found.
run(Name) ->
    case mgmtd_ems_inventory:lookup(Name) of
        {error, not_found} ->
            not_found;
        {ok, Node} ->
            apply_result(Name, mgmtd_ems_schema:sync(Node, #{}))
    end.

init(Name) ->
    ets:insert(?TAB, {key(Name), self()}),
    self() ! probe,
    {ok, #{name => Name, timer => undefined}}.

handle_call(probe, _From, State) ->
    {reply, {ok, run(maps:get(name, State))}, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(probe, #{name := Name} = State) ->
    case run(Name) of
        not_found ->
            {stop, normal, State};
        _ ->
            {noreply, schedule(cancel_timer(State))}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #{name := Name} = State) ->
    _ = cancel_timer(State),
    try ets:delete(?TAB, key(Name)) catch error:badarg -> ok end,
    ok;
terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

apply_result(Name, {ok, Entry, Root}) ->
    ok = mgmtd_ems_inventory:update(
           Name,
           #{status => up,
             last_seen => erlang:system_time(second),
             restconf_root => Root,
             module_set_id => maps:get(id, Entry),
             schema_ref => maps:get(id, Entry)}),
    up;
apply_result(Name, {error, Reason}) ->
    Status = classify(Reason),
    ok = mgmtd_ems_inventory:update(Name, #{status => Status}),
    Status.

classify({http, S, _}) when S =:= 401; S =:= 403 ->
    auth_error;
classify({schema_fetch, _, S, _}) when S =:= 401; S =:= 403 ->
    auth_error;
classify(_) ->
    down.

schedule(State) ->
    case interval() of
        Ms when is_integer(Ms), Ms > 0 ->
            State#{timer => erlang:send_after(Ms, self(), probe)};
        _ ->
            State#{timer => undefined}
    end.

cancel_timer(#{timer := TRef} = State) when is_reference(TRef) ->
    _ = erlang:cancel_timer(TRef),
    State#{timer => undefined};
cancel_timer(State) ->
    State.

interval() ->
    application:get_env(mgmtd_ems, probe_interval,
                        ?MGMTD_EMS_DEFAULT_PROBE_INTERVAL).

key(Name) when is_atom(Name); is_binary(Name) ->
    Name;
key(Name) when is_list(Name) ->
    list_to_binary(Name).
