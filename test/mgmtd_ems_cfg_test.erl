%%%-------------------------------------------------------------------
%%% Local mgmtd store for fleet nodes, applied to inventory.
%%%-------------------------------------------------------------------
-module(mgmtd_ems_cfg_test).

-include_lib("eunit/include/eunit.hrl").

-define(DB_DIR, "test_db_mgmtd_ems_cfg").

cfg_test_() ->
    {setup, fun setup/0, fun teardown/1,
     [fun add_node_persists/0,
      fun snapshot_fills_inventory/0,
      fun commit_delete_removes/0]}.

setup() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(?DB_DIR, [{backend, mnesia}]),
    application:load(mgmtd_ems),
    application:unset_env(mgmtd_ems, nodes),
    stop_inventory(),
    ok = mgmtd_ems_cfg:load(?DB_DIR),
    ok.

teardown(_) ->
    stop_inventory(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(?DB_DIR, [{backend, mnesia}]),
    ok.

start_mgmtd() ->
    case whereis(mgmtd_sup) of
        undefined ->
            case mgmtd_sup:start_link() of
                {ok, _} -> ok;
                {error, {already_started, _}} -> ok
            end;
        _ ->
            ok
    end.

stop_inventory() ->
    case whereis(mgmtd_ems_inventory) of
        undefined ->
            ok;
        Pid ->
            unlink(Pid),
            try gen_server:stop(Pid) catch _:_ -> ok end
    end.

start_inventory() ->
    stop_inventory(),
    {ok, Pid} = mgmtd_ems_inventory:start_link(),
    unlink(Pid),
    ok = mgmtd_ems_inventory:bind_config(),
    ok.

add_node_persists() ->
    start_inventory(),
    ?assertEqual(ok, mgmtd_ems:add_node(edge1, #{host => "192.0.2.10",
                                                port => 8443,
                                                tls => true})),
    ?assertEqual({ok, "192.0.2.10"},
                 mgmtd:lookup(["ems", "node", {"edge1"}, "host"])),
    ?assertEqual({ok, 8443},
                 mgmtd:lookup(["ems", "node", {"edge1"}, "port"])),
    ?assertEqual({ok, true},
                 mgmtd:lookup(["ems", "node", {"edge1"}, "tls"])),
    {ok, Node} = mgmtd_ems:node(edge1),
    ?assertEqual("192.0.2.10", maps:get(host, Node)),
    ?assertEqual(8443, maps:get(port, Node)),
    ?assertEqual(true, maps:get(tls, Node)).

snapshot_fills_inventory() ->
    ok = mgmtd_ems_cfg:put_node(pre, #{host => "192.0.2.20", port => 8008}),
    start_inventory(),
    wait_node(pre),
    {ok, Node} = mgmtd_ems:node(pre),
    ?assertEqual("192.0.2.20", maps:get(host, Node)),
    ?assertEqual(8008, maps:get(port, Node)).

commit_delete_removes() ->
    start_inventory(),
    ok = mgmtd_ems:add_node(gone, #{host => "192.0.2.21"}),
    wait_node(gone),
    ?assertEqual(ok, mgmtd_ems:remove_node(gone)),
    ?assertEqual({error, not_found}, mgmtd_ems:node(gone)),
    ?assertEqual({ok, undefined},
                 mgmtd:lookup(["ems", "node", {"gone"}, "host"])).

wait_node(Name) ->
    wait_fun(fun() ->
                     case mgmtd_ems:node(Name) of
                         {ok, _} -> true;
                         _ -> false
                     end
             end).

wait_fun(Pred) ->
    wait_fun(Pred, 50).

wait_fun(_Pred, 0) ->
    error(timeout);
wait_fun(Pred, N) ->
    case Pred() of
        true ->
            ok;
        false ->
            timer:sleep(20),
            wait_fun(Pred, N - 1)
    end.
