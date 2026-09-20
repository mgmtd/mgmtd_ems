%%%-------------------------------------------------------------------
%% @doc mgmtd_ems public API.
%%
%% Inventory of RESTCONF-speaking mgmtd nodes, southbound RESTCONF,
%% and a YANG schema cache keyed by yang-library `module-set-id`.
%% Configured fleet nodes are stored in this node's own mgmtd instance.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_ems).

-export([start/0]).
-export([add_node/2, remove_node/1, node/1, nodes/0, probe/1]).
-export([discover/1, yang_library/1, sync_schema/1, sync_schema/2,
         schema/1, schema_snapshot/1]).
-export([get/2, get/3, put/3, put/4, post/3, post/4,
         patch/3, patch/4, delete/2, delete/3]).

-export_type([node_name/0, node_spec/0, request_opts/0]).

-type node_name() :: atom() | binary() | string().
-type node_spec() :: #{
                       host := inet:hostname() | inet:ip_address() | string() | binary(),
                       port => inet:port_number(),
                       tls => boolean(),
                       user => string() | binary(),
                       password => string() | binary()
                      }.
-type request_opts() :: mgmtd_ems_restconf:opts().

start() ->
    application:ensure_all_started(?MODULE).

-spec add_node(node_name(), node_spec()) -> ok | {error, term()}.
add_node(Name, Spec) ->
    case mgmtd_ems_inventory:add(Name, Spec) of
        ok ->
            case mgmtd_ems_cfg:put_node(Name, Spec) of
                ok ->
                    _ = mgmtd_ems_sessions:ensure(Name),
                    ok;
                {error, _} = Err ->
                    _ = mgmtd_ems_inventory:remove(Name),
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

-spec remove_node(node_name()) -> ok | {error, not_found}.
remove_node(Name) ->
    case mgmtd_ems_inventory:lookup(Name) of
        {ok, Node} ->
            Real = maps:get(name, Node),
            _ = mgmtd_ems_sessions:stop(Real),
            ok = mgmtd_ems_inventory:remove(Real),
            _ = mgmtd_ems_cfg:delete_node(Real),
            ok;
        {error, _} = Err ->
            Err
    end.

-spec probe(node_name()) -> {ok, up | down | auth_error} | {error, term()}.
probe(Name) ->
    mgmtd_ems_sessions:probe(Name).

-spec node(node_name()) -> {ok, map()} | {error, not_found}.
node(Name) ->
    mgmtd_ems_inventory:lookup(Name).

-spec nodes() -> [map()].
nodes() ->
    mgmtd_ems_inventory:list().

-spec discover(node_name()) -> {ok, string()} | {error, term()}.
discover(Name) ->
    with_node(Name, fun(Node) ->
                            case mgmtd_ems_schema:discover(Node) of
                                {ok, Root} ->
                                    ok = mgmtd_ems_inventory:update(
                                           Name, #{restconf_root => Root}),
                                    {ok, Root};
                                {error, _} = Err ->
                                    Err
                            end
                    end).

-spec yang_library(node_name()) -> {ok, map()} | {error, term()}.
yang_library(Name) ->
    with_node(Name, fun mgmtd_ems_schema:yang_library/1).

-spec sync_schema(node_name()) -> {ok, map()} | {error, term()}.
sync_schema(Name) ->
    sync_schema(Name, #{}).

-spec sync_schema(node_name(), #{force => boolean()}) ->
          {ok, map()} | {error, term()}.
sync_schema(Name, Opts) ->
    with_node(Name, fun(Node) ->
                            case mgmtd_ems_schema:sync(Node, Opts) of
                                {ok, Entry, Root} ->
                                    ok = mgmtd_ems_inventory:update(
                                           Name,
                                           #{restconf_root => Root,
                                             module_set_id => maps:get(id, Entry),
                                             schema_ref => maps:get(id, Entry)}),
                                    {ok, Entry};
                                {error, _} = Err ->
                                    Err
                            end
                    end).

-spec schema(node_name()) -> {ok, map()} | {error, term()}.
schema(Name) ->
    with_node(Name, fun(Node) ->
                            case maps:get(schema_ref, Node, undefined) of
                                undefined ->
                                    {error, no_schema};
                                Ref ->
                                    mgmtd_ems_schema:lookup(Ref)
                            end
                    end).

%% JSON tree of the node's cached YANG (mgmtd_ui_schema shape), not a
%% fetch from the node. Requires the schema engine to have loaded the
%% cached modules into an isolated context.
-spec schema_snapshot(node_name()) -> {ok, map()} | {error, term()}.
schema_snapshot(Name) ->
    case schema(Name) of
        {error, _} = Err ->
            Err;
        {ok, Entry} ->
            case maps:get(ctx, Entry, undefined) of
                undefined ->
                    {error, no_engine};
                Ctx ->
                    {ok, mgmtd_schema:with_ctx(Ctx, fun mgmtd_ui_schema:snapshot/0)}
            end
    end.

-spec get(node_name(), iodata()) ->
          {ok, pos_integer(), [{string(), string()}], binary()} | {error, term()}.
get(Name, Path) ->
    request(Name, get, Path, undefined, #{}).

-spec get(node_name(), iodata(), request_opts()) ->
          {ok, pos_integer(), [{string(), string()}], binary()} | {error, term()}.
get(Name, Path, Opts) ->
    request(Name, get, Path, undefined, Opts).

-spec put(node_name(), iodata(), iodata() | map()) ->
          {ok, pos_integer(), [{string(), string()}], binary()} | {error, term()}.
put(Name, Path, Body) ->
    request(Name, put, Path, Body, #{}).

-spec put(node_name(), iodata(), iodata() | map(), request_opts()) ->
          {ok, pos_integer(), [{string(), string()}], binary()} | {error, term()}.
put(Name, Path, Body, Opts) ->
    request(Name, put, Path, Body, Opts).

-spec post(node_name(), iodata(), iodata() | map()) ->
          {ok, pos_integer(), [{string(), string()}], binary()} | {error, term()}.
post(Name, Path, Body) ->
    request(Name, post, Path, Body, #{}).

-spec post(node_name(), iodata(), iodata() | map(), request_opts()) ->
          {ok, pos_integer(), [{string(), string()}], binary()} | {error, term()}.
post(Name, Path, Body, Opts) ->
    request(Name, post, Path, Body, Opts).

-spec patch(node_name(), iodata(), iodata() | map()) ->
          {ok, pos_integer(), [{string(), string()}], binary()} | {error, term()}.
patch(Name, Path, Body) ->
    request(Name, patch, Path, Body, #{}).

-spec patch(node_name(), iodata(), iodata() | map(), request_opts()) ->
          {ok, pos_integer(), [{string(), string()}], binary()} | {error, term()}.
patch(Name, Path, Body, Opts) ->
    request(Name, patch, Path, Body, Opts).

-spec delete(node_name(), iodata()) ->
          {ok, pos_integer(), [{string(), string()}], binary()} | {error, term()}.
delete(Name, Path) ->
    request(Name, delete, Path, undefined, #{}).

-spec delete(node_name(), iodata(), request_opts()) ->
          {ok, pos_integer(), [{string(), string()}], binary()} | {error, term()}.
delete(Name, Path, Opts) ->
    request(Name, delete, Path, undefined, Opts).

request(Name, Method, Path, Body, Opts) ->
    with_node(Name, fun(Node) ->
                            mgmtd_ems_restconf:request(Node, Method, Path, Body, Opts)
                    end).

with_node(Name, Fun) ->
    case mgmtd_ems_inventory:lookup(Name) of
        {ok, Node} ->
            Fun(Node);
        {error, _} = Err ->
            Err
    end.
