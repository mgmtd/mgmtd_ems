-module(mgmtd_ems_restconf_test).

-include_lib("eunit/include/eunit.hrl").

url_data_suffix_test() ->
    Node = #{host => "192.0.2.10", port => 8008, tls => false},
    ?assertEqual("http://192.0.2.10:8008/restconf/data/ex:foo",
                 mgmtd_ems_restconf:url(Node, "data/ex:foo")).

url_absolute_test() ->
    Node = #{host => "192.0.2.10", port => 8008},
    ?assertEqual("http://192.0.2.10:8008/.well-known/host-meta",
                 mgmtd_ems_restconf:url(Node, "/.well-known/host-meta")).

url_tls_and_ipv6_test() ->
    Node = #{host => {0, 0, 0, 0, 0, 0, 0, 1}, port => 8443, tls => true},
    ?assertEqual("https://[::1]:8443/restconf/data",
                 mgmtd_ems_restconf:url(Node, "data")).

url_restconf_prefix_test() ->
    Node = #{host => "edge", port => 8008},
    ?assertEqual("http://edge:8008/restconf",
                 mgmtd_ems_restconf:url(Node, "restconf")),
    ?assertEqual("http://edge:8008/restconf/data",
                 mgmtd_ems_restconf:url(Node, "restconf/data")).

url_query_test() ->
    Node = #{host => "edge", port => 8008},
    ?assertEqual("http://edge:8008/restconf/data?with-defaults=trim",
                 mgmtd_ems_restconf:url(Node, "data",
                                        [{"with-defaults", "trim"}])),
    Url = mgmtd_ems_restconf:url(Node, "data",
                                 #{insert => "after", point => "ex:foo"}),
    #{query := Qs} = uri_string:parse(Url),
    Query = uri_string:dissect_query(Qs),
    ?assertEqual("after", proplists:get_value("insert", Query)),
    ?assertEqual("ex:foo", proplists:get_value("point", Query)).

json_roundtrip_test() ->
    Map = #{<<"ietf-restconf:errors">> =>
                #{<<"error">> =>
                      [#{<<"error-tag">> => <<"access-denied">>,
                         <<"error-message">> => <<"authentication required">>}]}},
    Bin = mgmtd_ems_json:encode(Map),
    {ok, Decoded} = mgmtd_ems_json:decode(Bin),
    ?assertEqual(Map, Decoded),
    [Err] = mgmtd_ems_restconf:errors(Bin),
    ?assertEqual(<<"access-denied">>, maps:get(<<"error-tag">>, Err)).

header_etag_test() ->
    Hdrs = [{"Content-Type", "application/yang-data+json"},
            {"ETag", "\"abc\""}],
    ?assertEqual("\"abc\"", mgmtd_ems_restconf:etag(Hdrs)),
    ?assertEqual("application/yang-data+json",
                 mgmtd_ems_restconf:header("content-type", Hdrs)),
    ?assertEqual(undefined, mgmtd_ems_restconf:header("if-match", Hdrs)).

unknown_node_test_() ->
    {setup, fun start_inv/0, fun stop_inv/1,
     fun() ->
             ?assertEqual({error, not_found}, mgmtd_ems:get(missing, "data"))
     end}.

start_inv() ->
    application:load(mgmtd_ems),
    application:unset_env(mgmtd_ems, nodes),
    case whereis(mgmtd_ems_inventory) of
        undefined -> ok;
        Pid -> gen_server:stop(Pid)
    end,
    {ok, _} = mgmtd_ems_inventory:start_link(),
    ok.

stop_inv(_) ->
    case whereis(mgmtd_ems_inventory) of
        undefined -> ok;
        Pid -> gen_server:stop(Pid)
    end.
