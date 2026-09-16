-module(mgmtd_ems_inventory_test).

-include_lib("eunit/include/eunit.hrl").

inventory_test_() ->
    {setup, fun setup/0, fun teardown/1,
     [fun add_lookup_list/0,
      fun default_port/0,
      fun duplicate_rejected/0,
      fun missing_host/0,
      fun remove_and_missing/0,
      fun string_name_key/0,
      fun binary_lookup_of_atom_name/0,
      fun update_schema_fields/0]}.

setup() ->
    application:load(mgmtd_ems),
    application:unset_env(mgmtd_ems, nodes),
    stop_stack(),
    {ok, _} = mgmtd_ems_inventory:start_link(),
    ok.

teardown(_) ->
    stop_stack().

stop_stack() ->
    case whereis(mgmtd_ems_sup) of
        Sup when is_pid(Sup) ->
            unlink_quiet(Sup),
            _ = gen_server:stop(Sup),
            ok;
        undefined ->
            ok
    end,
    case whereis(mgmtd_ems_inventory) of
        undefined ->
            ok;
        Inv ->
            gen_server:stop(Inv)
    end.

unlink_quiet(Pid) ->
    unlink(Pid),
    ok.

add_lookup_list() ->
    ?assertEqual(ok, mgmtd_ems:add_node(edge1, #{host => "192.0.2.10"})),
    {ok, Node} = mgmtd_ems:node(edge1),
    ?assertEqual(edge1, maps:get(name, Node)),
    ?assertEqual("192.0.2.10", maps:get(host, Node)),
    ?assertEqual(8008, maps:get(port, Node)),
    ?assertEqual(false, maps:get(tls, Node)),
    Names = [maps:get(name, N) || N <- mgmtd_ems:nodes()],
    ?assertEqual([edge1], Names).

default_port() ->
    ok = mgmtd_ems:add_node(edge2, #{host => "192.0.2.11", port => 8443, tls => true}),
    {ok, Node} = mgmtd_ems:node(edge2),
    ?assertEqual(8443, maps:get(port, Node)),
    ?assertEqual(true, maps:get(tls, Node)).

duplicate_rejected() ->
    ok = mgmtd_ems:add_node(dup, #{host => "192.0.2.12"}),
    ?assertEqual({error, already_exists},
                 mgmtd_ems:add_node(dup, #{host => "192.0.2.13"})).

missing_host() ->
    ?assertEqual({error, {missing_host, nohost}},
                 mgmtd_ems:add_node(nohost, #{port => 8008})).

remove_and_missing() ->
    ?assertEqual({error, not_found}, mgmtd_ems:remove_node(ghost)),
    ?assertEqual({error, not_found}, mgmtd_ems:node(ghost)),
    ok = mgmtd_ems:add_node(gone, #{host => "192.0.2.14"}),
    ?assertEqual(ok, mgmtd_ems:remove_node(gone)),
    ?assertEqual({error, not_found}, mgmtd_ems:node(gone)).

string_name_key() ->
    ok = mgmtd_ems:add_node("core1", #{host => "192.0.2.15"}),
    {ok, Node} = mgmtd_ems:node(<<"core1">>),
    ?assertEqual("core1", maps:get(name, Node)).

binary_lookup_of_atom_name() ->
    ok = mgmtd_ems:add_node(edgebin, #{host => "192.0.2.17"}),
    {ok, Node} = mgmtd_ems:node(<<"edgebin">>),
    ?assertEqual(edgebin, maps:get(name, Node)).

update_schema_fields() ->
    ok = mgmtd_ems:add_node(upd, #{host => "192.0.2.16"}),
    ok = mgmtd_ems_inventory:update(upd, #{schema_ref => <<"abc">>,
                                           restconf_root => "/restconf"}),
    {ok, Node} = mgmtd_ems:node(upd),
    ?assertEqual(<<"abc">>, maps:get(schema_ref, Node)),
    ?assertEqual("/restconf", maps:get(restconf_root, Node)),
    ?assertEqual(unknown, maps:get(status, Node)),
    ?assertEqual({error, not_found},
                 mgmtd_ems_inventory:update(ghost, #{schema_ref => <<"x">>})).
