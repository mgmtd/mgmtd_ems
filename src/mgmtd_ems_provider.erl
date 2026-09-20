%%%-------------------------------------------------------------------
%% @doc Operational status of managed fleet nodes.
%%
%% Serves the `status` tree from `mgmtd_ems_inventory` (probe result,
%% last seen, cached schema id). Named as `data_callback` on the
%% function schema loaded by `mgmtd_ems_cfg`.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_ems_provider).

-behaviour(mgmtd_provider).

-export([schema/0]).
-export([get_value/1, get_first/1, get_next/2, list_keys/3]).

-include_lib("mgmtd/include/mgmtd.hrl").

-define(NODE_LIST, ["status", "node"]).

schema() ->
    [#container{name = "status",
                desc = "Managed node operational status",
                config = false,
                data_callback = ?MODULE,
                children = fun status_children/0}].

status_children() ->
    [#list{name = "node",
           desc = "A managed RESTCONF node",
           key_names = ["name"],
           children = fun node_children/0}].

node_children() ->
    [#leaf{name = "name",
           desc = "Node name",
           type = string},
     #leaf{name = "host",
           desc = "RESTCONF hostname or address",
           type = string},
     #leaf{name = "port",
           desc = "RESTCONF port",
           type = 'inet:port-number'},
     #leaf{name = "tls",
           desc = "Using HTTPS",
           type = boolean},
     #leaf{name = "status",
           desc = "Last probe result",
           type = {enum, ["unknown", "up", "down", "auth-error"]}},
     #leaf{name = "last-seen",
           desc = "Time of last successful probe",
           type = string},
     #leaf{name = "restconf-root",
           desc = "Discovered RESTCONF root",
           type = string},
     #leaf{name = "module-set-id",
           desc = "yang-library module-set-id",
           type = string}].

%%--------------------------------------------------------------------
get_value(["status", "node", {Name}, Leaf]) ->
    case lookup_node(Name) of
        {ok, Node} ->
            leaf_value(Leaf, Node);
        {error, not_found} ->
            {ok, not_found}
    end;
get_value(_Path) ->
    {ok, not_found}.

get_first(?NODE_LIST) ->
    first_key(node_keys());
get_first(_Path) ->
    {ok, not_found}.

get_next(?NODE_LIST, Prev) ->
    next_key(node_keys(), Prev);
get_next(_Path, _Prev) ->
    {ok, not_found}.

list_keys(_Txn, Path, Match) ->
    case mgmtd_provider:list_keys(?MODULE, Path, Match) of
        {ok, Keys} ->
            Keys;
        {error, _} ->
            []
    end.

%%%===================================================================
%%% Internal
%%%===================================================================

leaf_value("host", Node) ->
    str_or_missing(maps:get(host, Node, undefined));
leaf_value("port", Node) ->
    case maps:get(port, Node, undefined) of
        P when is_integer(P) ->
            {ok, P};
        _ ->
            {ok, not_found}
    end;
leaf_value("tls", Node) ->
    {ok, maps:get(tls, Node, false)};
leaf_value("status", Node) ->
    {ok, status_name(maps:get(status, Node, unknown))};
leaf_value("last-seen", Node) ->
    case maps:get(last_seen, Node, undefined) of
        T when is_integer(T) ->
            {ok, rfc3339(T)};
        _ ->
            {ok, not_found}
    end;
leaf_value("restconf-root", Node) ->
    str_or_missing(maps:get(restconf_root, Node, undefined));
leaf_value("module-set-id", Node) ->
    str_or_missing(maps:get(module_set_id, Node, undefined));
leaf_value(_, _) ->
    {ok, not_found}.

status_name(up) -> "up";
status_name(down) -> "down";
status_name(auth_error) -> "auth-error";
status_name(_) -> "unknown".

str_or_missing(undefined) ->
    {ok, not_found};
str_or_missing("") ->
    {ok, not_found};
str_or_missing(<<>>) ->
    {ok, not_found};
str_or_missing(B) when is_binary(B) ->
    {ok, binary_to_list(B)};
str_or_missing(L) when is_list(L) ->
    {ok, L};
str_or_missing(A) when is_atom(A) ->
    {ok, atom_to_list(A)};
str_or_missing(Other) ->
    {ok, lists:flatten(io_lib:format("~p", [Other]))}.

rfc3339(T) ->
    case calendar:system_time_to_rfc3339(T, [{unit, second}]) of
        S when is_list(S) ->
            S;
        B when is_binary(B) ->
            binary_to_list(B)
    end.

node_keys() ->
    lists:usort([{name_str(maps:get(name, N))} || N <- inventory_nodes()]).

lookup_node(Name) ->
    case whereis(mgmtd_ems_inventory) of
        undefined ->
            {error, not_found};
        _ ->
            mgmtd_ems_inventory:lookup(Name)
    end.

inventory_nodes() ->
    case whereis(mgmtd_ems_inventory) of
        undefined ->
            [];
        _ ->
            mgmtd_ems_inventory:list()
    end.

name_str(Name) when is_atom(Name) ->
    atom_to_list(Name);
name_str(Name) when is_binary(Name) ->
    binary_to_list(Name);
name_str(Name) when is_list(Name) ->
    Name.

first_key([Key | _]) ->
    {ok, Key};
first_key([]) ->
    {ok, not_found}.

next_key([Prev, Next | _], Prev) ->
    {ok, Next};
next_key([_ | Rest], Prev) ->
    next_key(Rest, Prev);
next_key(_, _) ->
    {ok, not_found}.
