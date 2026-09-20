%%%-------------------------------------------------------------------
%%% EMS CLI: configure fleet nodes in the local mgmtd instance.
%%%-------------------------------------------------------------------
-module(mgmtd_ems_cli_test).

-include_lib("eunit/include/eunit.hrl").

-define(DB_DIR, "test_db_mgmtd_ems_cli").

cli_test_() ->
    {setup, fun setup/0, fun teardown/1,
     [fun expand_set_ems/0,
      fun set_commit_show/0,
      fun delete_commit/0,
      fun read_only_hides_configure/0,
      fun expand_show_status/0,
      fun show_status_lists_nodes/0]}.

setup() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(?DB_DIR, [{backend, mnesia}]),
    application:load(mgmtd_ems),
    application:unset_env(mgmtd_ems, nodes),
    stop_inventory(),
    ok = mgmtd_ems_cfg:load(?DB_DIR),
    {ok, Pid} = mgmtd_ems_inventory:start_link(),
    unlink(Pid),
    ok = mgmtd_ems_inventory:bind_config(),
    ok.

teardown(_) ->
    stop_inventory(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(?DB_DIR, [{backend, mnesia}]),
    restore_aaa(undefined),
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

expand_set_ems() ->
    {ok, J} = mgmtd_ems_cli:init(),
    {ok, _, J1} = mgmtd_ems_cli:execute("configure", J),
    {yes, Extra, _, _} = mgmtd_ems_cli:expand("set e", J1),
    ?assertEqual("ms ", Extra),
    {yes, " ", Menu, _} = mgmtd_ems_cli:expand("set ems", J1),
    MenuBin = iolist_to_binary(Menu),
    ?assertEqual(true, binary:match(MenuBin, <<"node">>) =/= nomatch).

set_commit_show() ->
    {ok, J} = mgmtd_ems_cli:init(),
    {ok, _, J1} = mgmtd_ems_cli:execute("configure", J),
    {ok, _, J2} =
        mgmtd_ems_cli:execute("set ems node edge1 host 192.0.2.10", J1),
    {ok, _, J3} =
        mgmtd_ems_cli:execute("set ems node edge1 port 8008", J2),
    {ok, _, J4} = mgmtd_ems_cli:execute("commit", J3),
    ?assertEqual({ok, "192.0.2.10"},
                 mgmtd:lookup(["ems", "node", {"edge1"}, "host"])),
    ?assertEqual({ok, 8008},
                 mgmtd:lookup(["ems", "node", {"edge1"}, "port"])),
    wait_host("edge1", "192.0.2.10"),
    {ok, Out, _} = mgmtd_ems_cli:execute("show", J4),
    Flat = iolist_to_binary(flatten(Out)),
    ?assertEqual(true, binary:match(Flat, <<"edge1">>) =/= nomatch),
    ?assertEqual(true, binary:match(Flat, <<"192.0.2.10">>) =/= nomatch).

delete_commit() ->
    {ok, J} = mgmtd_ems_cli:init(),
    {ok, _, J1} = mgmtd_ems_cli:execute("configure", J),
    {ok, _, J2} =
        mgmtd_ems_cli:execute("set ems node drop1 host 192.0.2.30", J1),
    {ok, _, J3} = mgmtd_ems_cli:execute("commit", J2),
    wait_node("drop1"),
    {ok, _, J4} = mgmtd_ems_cli:execute("delete ems node drop1", J3),
    {ok, _, _} = mgmtd_ems_cli:execute("commit", J4),
    wait_gone("drop1"),
    ?assertEqual({ok, undefined},
                 mgmtd:lookup(["ems", "node", {"drop1"}, "host"])).

read_only_hides_configure() ->
    Prev = application:get_env(mgmtd, aaa),
    application:set_env(mgmtd, aaa, [{default_role, read_only}]),
    try
        {ok, J} = mgmtd_ems_cli:init(#{uid => 4242, user => "guest"}),
        {no, [], Menu, J1} = mgmtd_ems_cli:expand([], J),
        MenuBin = iolist_to_binary(Menu),
        ?assertEqual(nomatch, binary:match(MenuBin, <<"configure">>)),
        ?assertEqual(true, binary:match(MenuBin, <<"show">>) =/= nomatch),
        {ok, Out, J2} = mgmtd_ems_cli:execute("configure", J1),
        {ok, Prompt} = mgmtd_ems_cli:prompt(J2),
        ?assertEqual(true, lists:suffix("> ", Prompt)),
        ?assertEqual(true, string:str(lists:flatten(Out), "not understood") > 0)
    after
        restore_aaa(Prev)
    end.

expand_show_status() ->
    {ok, J} = mgmtd_ems_cli:init(),
    {yes, Extra, _, _} = mgmtd_ems_cli:expand("show s", J),
    ?assertEqual("tatus ", Extra),
    {yes, " ", Menu, _} = mgmtd_ems_cli:expand("show status", J),
    MenuBin = iolist_to_binary(Menu),
    ?assertEqual(true, binary:match(MenuBin, <<"node">>) =/= nomatch).

show_status_lists_nodes() ->
    ok = mgmtd_ems:add_node(stat1, #{host => "192.0.2.40", port => 8008}),
    wait_node(stat1),
    ?assertEqual({ok, "unknown"},
                 mgmtd:lookup(["status", "node", {"stat1"}, "status"])),
    ?assertEqual({ok, "192.0.2.40"},
                 mgmtd:lookup(["status", "node", {"stat1"}, "host"])),
    {ok, J} = mgmtd_ems_cli:init(),
    {ok, Out, _} = mgmtd_ems_cli:execute("show status", J),
    Flat = iolist_to_binary(flatten(Out)),
    ?assertEqual(true, binary:match(Flat, <<"stat1">>) =/= nomatch),
    ?assertEqual(true, binary:match(Flat, <<"192.0.2.40">>) =/= nomatch),
    ?assertEqual(true, binary:match(Flat, <<"unknown">>) =/= nomatch),
    {ok, One, _} = mgmtd_ems_cli:execute("show status node stat1", J),
    OneBin = iolist_to_binary(flatten(One)),
    ?assertEqual(true, binary:match(OneBin, <<"stat1">>) =/= nomatch).

wait_node(Name) ->
    wait_fun(fun() ->
                     case mgmtd_ems:node(Name) of
                         {ok, _} -> true;
                         _ -> false
                     end
             end).

wait_host(Name, Host) ->
    wait_fun(fun() ->
                     case mgmtd_ems:node(Name) of
                         {ok, Node} -> maps:get(host, Node) =:= Host;
                         _ -> false
                     end
             end).

wait_gone(Name) ->
    wait_fun(fun() ->
                     mgmtd_ems:node(Name) =:= {error, not_found}
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

flatten({data, Tree}) ->
    io_lib:format("~p", [Tree]);
flatten(Out) when is_binary(Out) ->
    Out;
flatten(Out) ->
    Out.

restore_aaa(undefined) ->
    application:unset_env(mgmtd, aaa);
restore_aaa({ok, Val}) ->
    application:set_env(mgmtd, aaa, Val).
