%%%-------------------------------------------------------------------
%% @doc Session registry: start/stop per-node probe workers.
%%
%% Started after `mgmtd_ems_session_sup` so boot can spawn workers for
%% inventory already loaded from `sys.config`.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_ems_sessions).

-behaviour(gen_server).

-export([start_link/0, ensure/1, stop/1, probe/1, start_all/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(SUP, mgmtd_ems_session_sup).
-define(TAB, ?MODULE).
-define(PROBE_TIMEOUT, 30000).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec ensure(term()) -> ok | {error, term()}.
ensure(Name) ->
    case whereis(?SERVER) of
        undefined ->
            start_one(Name);
        _ ->
            gen_server:call(?SERVER, {ensure, Name})
    end.

-spec stop(term()) -> ok.
stop(Name) ->
    case whereis(?SERVER) of
        undefined ->
            stop_one(Name);
        _ ->
            gen_server:call(?SERVER, {stop, Name})
    end.

-spec probe(term()) -> {ok, up | down | auth_error} | {error, term()}.
probe(Name) ->
    case find(Name) of
        {ok, Pid} ->
            gen_server:call(Pid, probe, ?PROBE_TIMEOUT);
        {error, not_found} ->
            case mgmtd_ems_inventory:lookup(Name) of
                {ok, _} ->
                    case mgmtd_ems_session:run(Name) of
                        not_found ->
                            {error, not_found};
                        Status ->
                            {ok, Status}
                    end;
                {error, _} = Err ->
                    Err
            end
    end.

-spec start_all() -> ok.
start_all() ->
    lists:foreach(fun(Node) ->
                          _ = start_one(maps:get(name, Node))
                  end, mgmtd_ems_inventory:list()),
    ok.

init([]) ->
    start_all(),
    {ok, #{}}.

handle_call({ensure, Name}, _From, State) ->
    {reply, start_one(Name), State};
handle_call({stop, Name}, _From, State) ->
    {reply, stop_one(Name), State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

start_one(Name) ->
    case whereis(?SUP) of
        undefined ->
            ok;
        _ ->
            case find(Name) of
                {ok, Pid} ->
                    case is_process_alive(Pid) of
                        true ->
                            ok;
                        false ->
                            start_child(Name)
                    end;
                {error, not_found} ->
                    start_child(Name)
            end
    end.

start_child(Name) ->
    case supervisor:start_child(?SUP, [Name]) of
        {ok, _} ->
            ok;
        {ok, _, _} ->
            ok;
        {error, {already_started, _}} ->
            ok;
        {error, _} = Err ->
            Err
    end.

stop_one(Name) ->
    case find(Name) of
        {ok, Pid} ->
            case whereis(?SUP) of
                undefined ->
                    exit(Pid, shutdown);
                _ ->
                    case supervisor:terminate_child(?SUP, Pid) of
                        ok ->
                            ok;
                        {error, _} ->
                            exit(Pid, shutdown)
                    end
            end,
            try ets:delete(?TAB, key(Name)) catch error:badarg -> ok end,
            ok;
        {error, not_found} ->
            ok
    end.

find(Name) ->
    case ets:info(?TAB) of
        undefined ->
            {error, not_found};
        _ ->
            case ets:lookup(?TAB, key(Name)) of
                [{_, Pid}] when is_pid(Pid) ->
                    case is_process_alive(Pid) of
                        true ->
                            {ok, Pid};
                        false ->
                            try ets:delete(?TAB, key(Name))
                            catch error:badarg -> ok
                            end,
                            {error, not_found}
                    end;
                _ ->
                    {error, not_found}
            end
    end.

key(Name) when is_atom(Name); is_binary(Name) ->
    Name;
key(Name) when is_list(Name) ->
    list_to_binary(Name).
