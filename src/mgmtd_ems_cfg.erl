%%%-------------------------------------------------------------------
%% @doc Local mgmtd instance for EMS configuration.
%%
%% Fleet nodes live under `ems node <name> ...` and are the source of
%% truth once the config DB is open. Inventory is a runtime cache
%% (status, schema cache refs) updated from mgmtd subscriptions.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_ems_cfg).

-include_lib("mgmtd/include/mgmtd.hrl").
-include("mgmtd_ems.hrl").

-export([load/0, load/1, schema/0, db_ready/0]).
-export([put_node/2, delete_node/1, node_list_path/0]).

-define(NODE_LIST, ["ems", "node"]).

-spec node_list_path() -> [string()].
node_list_path() ->
    ?NODE_LIST.

%% @doc Load the EMS schema and open the config DB. Idempotent.
-spec load() -> ok | {error, term()}.
load() ->
    Dir = application:get_env(mgmtd_ems, db_dir, "db"),
    load(Dir).

-spec load(file:filename()) -> ok | {error, term()}.
load(Dir) ->
    ok = ensure_mgmtd(),
    case load_schema() of
        ok ->
            case ensure_db(Dir) of
                ok ->
                    import_env_nodes(),
                    ok;
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

-spec db_ready() -> boolean().
db_ready() ->
    try ets:lookup(mgmtd_meta, backend) of
        [{backend, _}] ->
            true;
        _ ->
            false
    catch
        error:badarg ->
            false
    end.

%% @doc Write a fleet node into the local config DB.
-spec put_node(term(), map()) -> ok | {error, term()}.
put_node(Name, Spec) when is_map(Spec) ->
    case db_ready() of
        false ->
            ok;
        true ->
            commit_node(Name, Spec)
    end.

%% @doc Remove a fleet node from the local config DB.
-spec delete_node(term()) -> ok | {error, term()}.
delete_node(Name) ->
    case db_ready() of
        false ->
            ok;
        true ->
            commit_delete(Name)
    end.

schema() ->
    [#container{name = "ems",
                desc = "Local element-management configuration",
                config = true,
                children = fun ems_children/0}].

%%%===================================================================
%%% Schema
%%%===================================================================

ems_children() ->
    [#list{name = "node",
           desc = "Managed RESTCONF node",
           key_names = ["name"],
           config = true,
           children = fun node_children/0}].

node_children() ->
    [#leaf{name = "name",
           desc = "Node name",
           type = string},
     #leaf{name = "host",
           desc = "RESTCONF hostname or address",
           type = string,
           mandatory = true},
     #leaf{name = "port",
           desc = "RESTCONF port",
           type = 'inet:port-number',
           default = ?MGMTD_EMS_DEFAULT_PORT},
     #leaf{name = "tls",
           desc = "Use HTTPS",
           type = boolean,
           default = false},
     #leaf{name = "user",
           desc = "HTTP Basic user",
           type = string},
     #leaf{name = "password",
           desc = "HTTP Basic password",
           type = string}].

%%%===================================================================
%%% Internal
%%%===================================================================

ensure_mgmtd() ->
    case whereis(mgmtd_sup) of
        undefined ->
            case mgmtd_sup:start_link() of
                {ok, _} ->
                    ok;
                {error, {already_started, _}} ->
                    ok;
                {error, _} = Err ->
                    Err
            end;
        _ ->
            ok
    end.

load_schema() ->
    case load_cfg_schema() of
        ok ->
            load_oper_schema();
        {error, _} = Err ->
            Err
    end.

load_cfg_schema() ->
    case mgmtd_schema:lookup(["ems"]) of
        #{} ->
            ok;
        false ->
            mgmtd:load_function_schema(fun schema/0, #{config => true})
    end.

load_oper_schema() ->
    case mgmtd_schema:lookup(["status"]) of
        #{} ->
            ok;
        false ->
            mgmtd:load_function_schema(fun mgmtd_ems_provider:schema/0)
    end.

ensure_db(Dir) ->
    case db_ready() of
        true ->
            ok;
        false ->
            mgmtd:load_config_db(Dir)
    end.

import_env_nodes() ->
    lists:foreach(fun import_env_node/1,
                  application:get_env(mgmtd_ems, nodes, [])).

import_env_node({Name, Spec}) when is_map(Spec) ->
    case has_node(Name) of
        true ->
            ok;
        false ->
            case maps:get(host, Spec, undefined) of
                undefined ->
                    ok;
                _ ->
                    _ = put_node(Name, Spec),
                    ok
            end
    end;
import_env_node(_) ->
    ok.

has_node(Name) ->
    NameStr = name_str(Name),
    case mgmtd:lookup(?NODE_LIST) of
        {ok, Keys} when is_list(Keys) ->
            lists:member({NameStr}, Keys);
        _ ->
            false
    end.

commit_node(Name, Spec) ->
    NameStr = name_str(Name),
    Key = {NameStr},
    Leaves = node_leaves(Spec),
    Txn0 = mgmtd:txn_new(),
    case set_leaves(Txn0, Key, Leaves) of
        {ok, Txn1} ->
            finish_txn(mgmtd:txn_commit(Txn1), Txn1);
        {error, _} = Err ->
            _ = safe_exit(Txn0),
            Err
    end.

node_leaves(Spec) ->
    Host = maps:get(host, Spec),
    Port = maps:get(port, Spec, ?MGMTD_EMS_DEFAULT_PORT),
    Tls = maps:get(tls, Spec, false),
    Base = [{"host", host_str(Host)},
            {"port", Port},
            {"tls", Tls}],
    optional_leaf("user", maps:get(user, Spec, undefined),
                  optional_leaf("password", maps:get(password, Spec, undefined),
                                Base)).

optional_leaf(_Name, undefined, Acc) ->
    Acc;
optional_leaf(_Name, "", Acc) ->
    Acc;
optional_leaf(_Name, <<>>, Acc) ->
    Acc;
optional_leaf(Name, Val, Acc) ->
    [{Name, Val} | Acc].

set_leaves(Txn, _Key, []) ->
    {ok, Txn};
set_leaves(Txn, Key, [{Leaf, Value} | Rest]) ->
    Path = ?NODE_LIST ++ [Key, Leaf, value_token(Value)],
    case mgmtd_schema:lookup_path(Path) of
        {ok, SchemaPath} ->
            case mgmtd:txn_set(Txn, SchemaPath) of
                {ok, Txn1} ->
                    set_leaves(Txn1, Key, Rest);
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

commit_delete(Name) ->
    NameStr = name_str(Name),
    case mgmtd_schema:lookup_path(?NODE_LIST ++ [{NameStr}]) of
        {ok, SchemaPath} ->
            Txn0 = mgmtd:txn_new(),
            case mgmtd:txn_delete(Txn0, SchemaPath) of
                {ok, Txn1} ->
                    finish_txn(mgmtd:txn_commit(Txn1), Txn1);
                {error, _} = Err ->
                    _ = safe_exit(Txn0),
                    Err
            end;
        {error, _} ->
            ok
    end.

finish_txn({ok, Txn}, _) ->
    _ = safe_exit(Txn),
    ok;
finish_txn({error, _} = Err, Txn) ->
    _ = safe_exit(Txn),
    Err.

safe_exit(Txn) ->
    try mgmtd:txn_exit(Txn) of
        _ ->
            ok
    catch
        _:_ ->
            ok
    end.

name_str(Name) when is_atom(Name) ->
    atom_to_list(Name);
name_str(Name) when is_binary(Name) ->
    binary_to_list(Name);
name_str(Name) when is_list(Name) ->
    Name.

host_str(Host) when is_list(Host) ->
    Host;
host_str(Host) when is_binary(Host) ->
    binary_to_list(Host);
host_str(Host) when is_tuple(Host) ->
    case inet:ntoa(Host) of
        {error, _} ->
            lists:flatten(io_lib:format("~p", [Host]));
        Str ->
            Str
    end;
host_str(Host) ->
    lists:flatten(io_lib:format("~p", [Host])).

value_token(true) ->
    "true";
value_token(false) ->
    "false";
value_token(I) when is_integer(I) ->
    integer_to_list(I);
value_token(B) when is_binary(B) ->
    binary_to_list(B);
value_token(L) when is_list(L) ->
    L;
value_token(A) when is_atom(A) ->
    atom_to_list(A).
