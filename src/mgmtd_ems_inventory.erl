%%%-------------------------------------------------------------------
%% @doc In-memory inventory of managed RESTCONF nodes.
%%
%% Seeded from `{mgmtd_ems, [{nodes, [{Name, Spec}, ...]}]}`.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_ems_inventory).

-behaviour(gen_server).

-include("mgmtd_ems.hrl").

-export([start_link/0,
         add/2,
         remove/1,
         lookup/1,
         update/2,
         list/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

add(Name, Spec) ->
    gen_server:call(?SERVER, {add, Name, Spec}).

remove(Name) ->
    gen_server:call(?SERVER, {remove, Name}).

lookup(Name) ->
    gen_server:call(?SERVER, {lookup, Name}).

update(Name, Fields) when is_map(Fields) ->
    gen_server:call(?SERVER, {update, Name, Fields}).

list() ->
    gen_server:call(?SERVER, list).

init([]) ->
    Seed = application:get_env(mgmtd_ems, nodes, []),
    case load_seed(Seed, #{}) of
        {ok, Nodes} ->
            {ok, #{nodes => Nodes}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call({add, Name, Spec}, _From, #{nodes := Nodes} = State) ->
    Key = key(Name),
    case maps:is_key(Key, Nodes) of
        true ->
            {reply, {error, already_exists}, State};
        false ->
            case normalize(Name, Spec) of
                {ok, Node} ->
                    {reply, ok, State#{nodes := Nodes#{Key => Node}}};
                {error, _} = Err ->
                    {reply, Err, State}
            end
    end;
handle_call({remove, Name}, _From, #{nodes := Nodes} = State) ->
    case find_key(Name, Nodes) of
        {ok, Key} ->
            {reply, ok, State#{nodes := maps:remove(Key, Nodes)}};
        error ->
            {reply, {error, not_found}, State}
    end;
handle_call({lookup, Name}, _From, #{nodes := Nodes} = State) ->
    case find_key(Name, Nodes) of
        {ok, Key} ->
            {reply, {ok, maps:get(Key, Nodes)}, State};
        error ->
            {reply, {error, not_found}, State}
    end;
handle_call({update, Name, Fields}, _From, #{nodes := Nodes} = State) ->
    case find_key(Name, Nodes) of
        {ok, Key} ->
            Node = maps:get(Key, Nodes),
            Merged = maps:merge(Node, maps:remove(name, Fields)),
            {reply, ok, State#{nodes := Nodes#{Key => Merged}}};
        error ->
            {reply, {error, not_found}, State}
    end;
handle_call(list, _From, #{nodes := Nodes} = State) ->
    {reply, maps:values(Nodes), State};
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

-spec load_seed(list(), #{term() => map()}) ->
          {ok, #{term() => map()}} | {error, term()}.
load_seed([], Acc) ->
    {ok, Acc};
load_seed([{Name, Spec} | Rest], Acc) ->
    case normalize(Name, Spec) of
        {ok, Node} ->
            load_seed(Rest, Acc#{key(Name) => Node});
        {error, _} = Err ->
            Err
    end;
load_seed([Other | _], _Acc) ->
    {error, {invalid_node, Other}}.

key(Name) when is_atom(Name); is_binary(Name) ->
    Name;
key(Name) when is_list(Name) ->
    list_to_binary(Name).

%% URL bindings are binaries; shell-added nodes are often atoms.
find_key(Name, Nodes) ->
    Key = key(Name),
    case maps:is_key(Key, Nodes) of
        true ->
            {ok, Key};
        false ->
            alt_key(Name, Nodes)
    end.

alt_key(Name, Nodes) when is_binary(Name) ->
    try binary_to_existing_atom(Name, utf8) of
        A ->
            case maps:is_key(A, Nodes) of
                true -> {ok, A};
                false -> error
            end
    catch
        error:badarg ->
            error
    end;
alt_key(Name, Nodes) when is_atom(Name) ->
    Bin = atom_to_binary(Name, utf8),
    case maps:is_key(Bin, Nodes) of
        true -> {ok, Bin};
        false -> error
    end;
alt_key(Name, Nodes) when is_list(Name) ->
    find_key(list_to_binary(Name), Nodes);
alt_key(_, _) ->
    error.

-spec normalize(term(), map()) -> {ok, map()} | {error, term()}.
normalize(Name, Spec) when is_map(Spec) ->
    case maps:get(host, Spec, undefined) of
        undefined ->
            {error, {missing_host, Name}};
        Host ->
            {ok, #{name => Name,
                   host => Host,
                   port => maps:get(port, Spec, ?MGMTD_EMS_DEFAULT_PORT),
                   tls => maps:get(tls, Spec, false),
                   user => maps:get(user, Spec, undefined),
                   password => maps:get(password, Spec, undefined),
                   status => unknown,
                   last_seen => undefined,
                   restconf_root => undefined,
                   module_set_id => undefined,
                   schema_ref => undefined}}
    end;
normalize(Name, Spec) ->
    {error, {invalid_spec, Name, Spec}}.
