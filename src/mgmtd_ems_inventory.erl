%%%-------------------------------------------------------------------
%% @doc Runtime inventory of managed RESTCONF nodes.
%%
%% Configured fields (host, port, tls, user, password) are stored in
%% the local mgmtd instance. This process keeps that copy plus
%% operational overlay (status, schema refs) and is seeded from
%% `{mgmtd_ems, [{nodes, ...}]}` when mgmtd is not yet open.
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
         list/0,
         bind_config/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(NODE_LIST, ["ems", "node"]).

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

%% @doc Subscribe to the local mgmtd fleet-node list. No-op when the
%% config DB is not open. Idempotent.
-spec bind_config() -> ok.
bind_config() ->
    case whereis(?SERVER) of
        undefined ->
            ok;
        _ ->
            gen_server:call(?SERVER, bind_config)
    end.

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
handle_call(bind_config, _From, State) ->
    {reply, ok, do_bind(State)};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({config_change, Ref, Ops}, #{cfg_ref := Ref} = State) ->
    {State1, Affected} = lists:foldl(fun apply_op/2, {State, []}, Ops),
    lists:foreach(fun(Name) -> maybe_restart(Name, State1) end,
                  lists:usort(Affected)),
    {noreply, State1};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    case maps:get(cfg_ref, State, undefined) of
        undefined ->
            ok;
        Ref ->
            try mgmtd_cfg_server:unsubscribe(Ref) of
                _ ->
                    ok
            catch
                _:_ ->
                    ok
            end
    end,
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

do_bind(#{cfg_ref := _} = State) ->
    State;
do_bind(State) ->
    try mgmtd:subscribe(?NODE_LIST, self()) of
        {ok, Ref} ->
            State#{cfg_ref => Ref};
        {error, _} ->
            State
    catch
        _:_ ->
            State
    end.

apply_op({delete, ?NODE_LIST, {Name}}, {#{nodes := Nodes} = State, Affected}) ->
    case find_key(Name, Nodes) of
        {ok, Key} ->
            Node = maps:get(Key, Nodes),
            _ = mgmtd_ems_sessions:stop(maps:get(name, Node)),
            {State#{nodes := maps:remove(Key, Nodes)}, Affected};
        error ->
            {State, Affected}
    end;
apply_op({add, ?NODE_LIST, {Name}}, {#{nodes := Nodes} = State, Affected}) ->
    Fields = config_fields(Name),
    {State#{nodes := upsert_node(Name, Fields, Nodes)}, [Name | Affected]};
apply_op({set, Path, Value}, {#{nodes := Nodes} = State, Affected}) ->
    case path_leaf(Path) of
        {Name, Leaf} ->
            case field(Leaf) of
                undefined ->
                    {State, Affected};
                F ->
                    Nodes1 = apply_set(Name, F, Value, Nodes),
                    {State#{nodes := Nodes1}, [Name | Affected]}
            end;
        error ->
            {State, Affected}
    end;
apply_op(_Op, Acc) ->
    Acc.

path_leaf(["ems", "node", {Name}, Leaf | _]) ->
    {Name, Leaf};
path_leaf(_) ->
    error.

field("host") -> host;
field("port") -> port;
field("tls") -> tls;
field("user") -> user;
field("password") -> password;
field(_) -> undefined.

apply_set(Name, Field, Value, Nodes) ->
    case find_key(Name, Nodes) of
        {ok, Key} ->
            Node = maps:get(Key, Nodes),
            Nodes#{Key => Node#{Field => Value}};
        error ->
            upsert_node(Name, (config_fields(Name))#{Field => Value}, Nodes)
    end.

upsert_node(Name, Fields, Nodes) ->
    case find_key(Name, Nodes) of
        {ok, Key} ->
            Node = maps:get(Key, Nodes),
            Nodes#{Key => maps:merge(Node, Fields)};
        error ->
            Nodes#{key(Name) => runtime_node(Name, Fields)}
    end.

runtime_node(Name, Fields) ->
    #{name => Name,
      host => maps:get(host, Fields, undefined),
      port => maps:get(port, Fields, ?MGMTD_EMS_DEFAULT_PORT),
      tls => maps:get(tls, Fields, false),
      user => maps:get(user, Fields, undefined),
      password => maps:get(password, Fields, undefined),
      status => unknown,
      last_seen => undefined,
      restconf_root => undefined,
      module_set_id => undefined,
      schema_ref => undefined}.

config_fields(Name) ->
    NameStr = name_str(Name),
    Key = {NameStr},
    Base = ?NODE_LIST ++ [Key],
    #{host => cfg_leaf(Base ++ ["host"]),
      port => cfg_leaf_default(Base ++ ["port"], ?MGMTD_EMS_DEFAULT_PORT),
      tls => cfg_leaf_default(Base ++ ["tls"], false),
      user => cfg_leaf(Base ++ ["user"]),
      password => cfg_leaf(Base ++ ["password"])}.

cfg_leaf(Path) ->
    case mgmtd:lookup(Path) of
        {ok, undefined} ->
            undefined;
        {ok, Val} ->
            Val;
        _ ->
            undefined
    end.

cfg_leaf_default(Path, Default) ->
    case cfg_leaf(Path) of
        undefined ->
            Default;
        Val ->
            Val
    end.

name_str(Name) when is_atom(Name) ->
    atom_to_list(Name);
name_str(Name) when is_binary(Name) ->
    binary_to_list(Name);
name_str(Name) when is_list(Name) ->
    Name.

maybe_restart(Name, #{nodes := Nodes}) ->
    case find_key(Name, Nodes) of
        {ok, Key} ->
            Node = maps:get(Key, Nodes),
            case maps:get(host, Node, undefined) of
                undefined ->
                    ok;
                "" ->
                    ok;
                _ ->
                    Real = maps:get(name, Node),
                    _ = mgmtd_ems_sessions:stop(Real),
                    _ = mgmtd_ems_sessions:ensure(Real),
                    ok
            end;
        error ->
            ok
    end.
