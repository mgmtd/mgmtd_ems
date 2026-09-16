%%%-------------------------------------------------------------------
%% @doc Schema-driven HTML UI for a fleet of RESTCONF nodes.
%%
%% Inventory at `/`. Per-node tree/pane at `/nodes/:name`, driven by
%% `mgmtd_ems:schema_snapshot/1` (YANG) and southbound RESTCONF.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_ems_ui).

-export([inventory/1, add_node/1, remove_node/1,
         http_get/2, http_post/2, compile/0]).

-define(CSS, <<"/static/ems_ui.css">>).
-define(HTML, <<"text/html; charset=utf-8">>).

%%--------------------------------------------------------------------
%% Inventory
%%--------------------------------------------------------------------

inventory(Req) ->
    html_reply(200, inventory_page(qs_val(cowboy_req:parse_qs(Req), <<"error">>)), Req).

add_node(Req0) ->
    {ok, Qs, Req} = cowboy_req:read_urlencoded_body(Req0),
    Name = string:trim(qs_val(Qs, <<"name">>)),
    Host = string:trim(qs_val(Qs, <<"host">>)),
    case {Name, Host} of
        {<<>>, _} ->
            html_reply(200, inventory_page(<<"name is required">>), Req);
        {_, <<>>} ->
            html_reply(200, inventory_page(<<"host is required">>), Req);
        _ ->
            Spec = #{host => binary_to_list(Host),
                     port => parse_port(qs_val(Qs, <<"port">>, <<"8008">>)),
                     tls => qs_val(Qs, <<"tls">>) =:= <<"true">>,
                     user => empty_to_undef(qs_val(Qs, <<"user">>)),
                     password => empty_to_undef(qs_val(Qs, <<"password">>))},
            case mgmtd_ems:add_node(Name, Spec) of
                ok ->
                    cowboy_req:reply(303, #{<<"location">> => <<"/">>}, <<>>, Req);
                {error, already_exists} ->
                    html_reply(200, inventory_page(<<"node already exists">>), Req);
                {error, Reason} ->
                    html_reply(200, inventory_page(err_msg(Reason)), Req)
            end
    end.

remove_node(Req) ->
    Name = cowboy_req:binding(name, Req),
    _ = mgmtd_ems:remove_node(Name),
    cowboy_req:reply(303, #{<<"location">> => <<"/">>}, <<>>, Req).

inventory_page(Error) ->
    ensure_compiled(),
    Rows = [inv_row(N) || N <- lists:sort(fun inv_ord/2, mgmtd_ems:nodes())],
    Vars = [{css_href, ?CSS},
            {empty, Rows =:= []},
            {nodes, Rows}],
    tpl(ems_ui_index_dtl, put_text(Vars, error, nonempty(Error))).

inv_ord(A, B) ->
    to_bin(maps:get(name, A)) =< to_bin(maps:get(name, B)).

inv_row(Node) ->
    NameB = to_bin(maps:get(name, Node)),
    Host = to_bin(maps:get(host, Node)),
    Port = integer_to_binary(maps:get(port, Node)),
    Addr = case maps:get(tls, Node, false) of
               true -> <<"https://", Host/binary, $:, Port/binary>>;
               false -> <<Host/binary, $:, Port/binary>>
           end,
    Schema = case maps:get(module_set_id, Node, undefined) of
                 undefined -> <<"—"/utf8>>;
                 Id -> to_bin(Id)
             end,
    [{name, NameB},
     {href, <<"/nodes/", NameB/binary>>},
     {remove_href, <<"/nodes/", NameB/binary, "/remove">>},
     {address, Addr},
     {status, to_bin(maps:get(status, Node, unknown))},
     {schema, Schema}].

%%--------------------------------------------------------------------
%% Per-node GET / POST
%%--------------------------------------------------------------------

http_get(Kind, Req) ->
    case cowboy_req:binding(name, Req) of
        undefined ->
            cowboy_req:reply(404, #{}, <<"not found">>, Req);
        Name ->
            case mgmtd_ems:node(Name) of
                {error, not_found} ->
                    cowboy_req:reply(404, #{}, <<"not found">>, Req);
                {ok, Node} ->
                    Qs = cowboy_req:parse_qs(Req),
                    Path = qs_val(Qs, <<"path">>),
                    Opts = case lists:keyfind(<<"mode">>, 1, Qs) of
                               {_, V} -> #{mode => parse_mode(V)};
                               false -> #{}
                           end,
                    Body = node_page(Kind, Node, Path, Opts),
                    html_reply(200, Body, Req)
            end
    end.

http_post(Action, Req0) ->
    Name = cowboy_req:binding(name, Req0),
    {ok, Qs, Req} = cowboy_req:read_urlencoded_body(Req0),
    case mgmtd_ems:node(Name) of
        {error, not_found} ->
            cowboy_req:reply(404, #{}, <<"not found">>, Req);
        {ok, Node} ->
            finish(Node, case Action of
                             save -> save(Name, Qs);
                             add -> add(Name, Qs);
                             delete -> delete(Name, Qs)
                         end, Req)
    end.

save(Name, Qs) ->
    Path = qs_val(Qs, <<"path">>),
    Return = qs_val(Qs, <<"return">>, Path),
    View = qs_val(Qs, <<"view">>, <<"index">>),
    Mode = parse_mode(qs_val(Qs, <<"mode">>)),
    Etag = qs_val(Qs, <<"etag">>),
    Raw = qs_val(Qs, <<"value">>),
    case find_node(Path, modules(Name)) of
        #{<<"kind">> := Kind} = Schema
          when Kind =:= <<"leaf">>; Kind =:= <<"leaf-list">> ->
            Parse = case Kind of
                        <<"leaf-list">> -> parse_snapshot_leaf_list(Schema, Raw);
                        <<"leaf">> -> parse_snapshot_leaf(Schema, Raw)
                    end,
            case Parse of
                {error, Msg} ->
                    {error, Return, View, Mode, #{Path => Msg}, #{}};
                {ok, Val} ->
                    Body = #{maps:get(<<"qname">>, Schema) => Val},
                    case apply_save(Name, Path, Body, Etag) of
                        ok ->
                            {ok, Return, View, Mode};
                        {error, Err} ->
                            {error, Return, View, Mode, #{Path => err_msg(Err)}, #{}}
                    end
            end;
        _ ->
            {error, Return, View, Mode, #{Path => <<"cannot write this resource">>}, #{}}
    end.

add(Name, Qs) ->
    Path = qs_val(Qs, <<"path">>),
    Return = qs_val(Qs, <<"return">>, Path),
    View = qs_val(Qs, <<"view">>, <<"index">>),
    Mode = parse_mode(qs_val(Qs, <<"mode">>)),
    Etag = qs_val(Qs, <<"etag">>),
    Draft = collect_item(Qs),
    case find_node(Path, modules(Name)) of
        undefined ->
            {error, Return, View, Mode, #{<<"add">> => <<"unknown list">>}, Draft};
        Node ->
            case build_item(Node, Draft, <<"item">>) of
                {error, FieldErrs} ->
                    {error, Return, View, Mode, FieldErrs, Draft};
                {ok, Item} ->
                    Body = #{maps:get(<<"qname">>, Node) => [Item]},
                    case restconf_result(mgmtd_ems:post(Name, Path, Body, etag_opts(Etag))) of
                        ok ->
                            {ok, Return, View, Mode};
                        {error, Err} ->
                            {error, Return, View, Mode, #{<<"add">> => err_msg(Err)}, Draft}
                    end
            end
    end.

delete(Name, Qs) ->
    Path = qs_val(Qs, <<"path">>),
    Return = qs_val(Qs, <<"return">>, Path),
    View = qs_val(Qs, <<"view">>, <<"index">>),
    Mode = parse_mode(qs_val(Qs, <<"mode">>)),
    Etag = qs_val(Qs, <<"etag">>),
    case restconf_result(mgmtd_ems:delete(Name, Path, etag_opts(Etag))) of
        ok ->
            {ok, Return, View, Mode};
        {error, Err} ->
            {error, Return, View, Mode, #{<<"page">> => err_msg(Err)}, #{}}
    end.

apply_save(Name, Path, Body, Etag) ->
    Opts = etag_opts(Etag),
    case mgmtd_ems:patch(Name, Path, Body, Opts) of
        {ok, 404, _, _} ->
            restconf_result(mgmtd_ems:put(Name, Path, Body, Opts));
        Other ->
            restconf_result(Other)
    end.

restconf_result({ok, S, _, _}) when S >= 200, S < 300 ->
    ok;
restconf_result({ok, 404, _, _}) ->
    {error, <<"not found">>};
restconf_result({ok, 412, _, _}) ->
    {error, <<"precondition failed">>};
restconf_result({ok, _, _, Body}) ->
    case mgmtd_ems_restconf:errors(Body) of
        [Err | _] ->
            {error, err_msg(Err)};
        [] ->
            {error, <<"request failed">>}
    end;
restconf_result({error, _}) ->
    {error, <<"node unreachable">>}.

etag_opts(<<>>) -> #{};
etag_opts(undefined) -> #{};
etag_opts(Etag) -> #{etag => Etag}.

finish(Node, {ok, Return, View, Mode}, Req) ->
    cowboy_req:reply(303, #{<<"location">> => loc(Node, View, Return, Mode)}, <<>>, Req);
finish(Node, {error, Return, View, Mode, Errors, Draft}, Req) ->
    Body = node_page(view_kind(View), Node, Return,
                     #{errors => Errors, draft => Draft, mode => Mode}),
    html_reply(200, Body, Req).

%%--------------------------------------------------------------------
%% Page
%%--------------------------------------------------------------------

node_page(Kind, Node, Path, Opts) ->
    ensure_compiled(),
    Name = maps:get(name, Node),
    Status = maps:get(status, Node, unknown),
    {Banner, Mods} = case mgmtd_ems:schema_snapshot(Name) of
                         {ok, Snap} ->
                             {status_banner(Status), maps:get(<<"modules">>, Snap, [])};
                         {error, no_schema} ->
                             {<<"No YANG cached yet. The node is probed on add; wait or check status.">>, []};
                         {error, no_engine} ->
                             {<<"YANG is cached but the schema engine could not load it.">>, []};
                         {error, _} ->
                             {<<"Could not load schema.">>, []}
                     end,
    Mode = case maps:find(mode, Opts) of
               {ok, M} -> M;
               error -> infer_mode(Path, Mods)
           end,
    Filtered = filter_modules(Mods, Mode),
    Selected = find_node(Path, Filtered),
    Errors = maps:get(errors, Opts, #{}),
    Draft = maps:get(draft, Opts, #{}),
    PageBase = page_base(Name, Kind),
    View = view_name(Kind),
    Tree = render_modules(Filtered, Path, PageBase, Mode),
    Pane = render_pane(Name, Selected, Path, Errors, Draft, View, Mode, Mods),
    Host = to_bin(maps:get(host, Node)),
    Port = integer_to_binary(maps:get(port, Node)),
    Vars = [{css_href, ?CSS},
            {include_css, Kind =:= content},
            {include_mode_switch, Kind =:= content},
            {empty_schema, Filtered =:= []},
            {empty_tree, empty_tree_msg(Mode)},
            {tree_label, tree_label(Mode)},
            {mode, mode_bin(Mode)},
            {node_name, to_bin(Name)},
            {status, to_bin(Status)},
            {address, <<Host/binary, $:, Port/binary>>},
            {mode_switch_html, html(render_mode_switch(Name, View, Path, Mods, Mode))},
            {tree_html, html(Tree)},
            {pane_html, html(Pane)}],
    Vars1 = put_text(Vars, banner, nonempty(maps:get(banner, Opts, Banner))),
    tpl(page_mod(Kind), Vars1).

page_mod(index) -> ems_ui_node_dtl;
page_mod(content) -> ems_ui_content_dtl.

page_base(Name, index) -> ui_base(Name);
page_base(Name, content) -> <<(ui_base(Name))/binary, "/content">>.

ui_base(Name) ->
    <<"/nodes/", (to_bin(Name))/binary>>.

view_name(index) -> <<"index">>;
view_name(content) -> <<"content">>.

view_kind(<<"content">>) -> content;
view_kind(_) -> index.

modules(Name) ->
    case mgmtd_ems:schema_snapshot(Name) of
        {ok, Snap} -> maps:get(<<"modules">>, Snap, []);
        {error, _} -> []
    end.

status_banner(up) -> undefined;
status_banner(unknown) -> <<"Status unknown — first probe may still be running.">>;
status_banner(down) -> <<"Node is down. Showing last cached schema; reads/writes may fail.">>;
status_banner(auth_error) -> <<"Authentication failed. Check user/password.">>;
status_banner(_) -> undefined.

html_reply(Status, Body, Req) ->
    Headers = #{<<"content-type">> => ?HTML,
                <<"content-length">> => integer_to_binary(byte_size(Body))},
    case cowboy_req:method(Req) of
        <<"HEAD">> ->
            cowboy_req:reply(Status, Headers, <<>>, Req);
        _ ->
            cowboy_req:reply(Status, Headers, Body, Req)
    end.

loc(Node, View, Path, Mode) ->
    loc_href(page_base(maps:get(name, Node), view_kind(View)), Path, Mode).

loc_href(Base, Path, Mode) ->
    case path_qs(Path) ++ mode_qs(Mode) of
        [] -> Base;
        Parts -> <<Base/binary, $?, (join_and(Parts))/binary>>
    end.

path_qs(<<>>) -> [];
path_qs(Path) ->
    Quoted = uri_quote(to_bin(Path)),
    [<<"path=", Quoted/binary>>].

mode_qs(oper) -> [<<"mode=oper">>];
mode_qs(config) -> [].

join_and([P]) -> P;
join_and([P | Rest]) -> <<P/binary, $&, (join_and(Rest))/binary>>.

%%--------------------------------------------------------------------
%% Tree
%%--------------------------------------------------------------------

render_modules(Mods, Selected, PageBase, Mode) ->
    Items = [render_mod_node(M, Selected, PageBase, Mode) || M <- Mods],
    [<<"<ul class=\"tree-list tree-root\">">>, Items, <<"</ul>">>].

render_mod_node(M, Selected, PageBase, Mode) ->
    Kids = maps:get(<<"children">>, M, []),
    Node = [{name, maps:get(<<"name">>, M)},
            {is_link, false},
            {href, <<>>},
            {selected, false},
            {open, true},
            {has_kids, Kids =/= []},
            {config, true},
            {kind_label, <<>>}],
    render_tree_node(Node, render_nodes(Kids, Selected, PageBase, 0, Mode)).

render_nodes([], _Selected, _PageBase, _Depth, _Mode) ->
    <<>>;
render_nodes(Nodes, Selected, PageBase, Depth, Mode) ->
    Items = [render_schema_node(N, Selected, PageBase, Depth, Mode) || N <- Nodes],
    [<<"<ul class=\"tree-list\">">>, Items, <<"</ul>">>].

render_schema_node(N, Selected, PageBase, Depth, Mode) ->
    Path = maps:get(<<"path">>, N),
    Kind = maps:get(<<"kind">>, N),
    Kids0 = maps:get(<<"children">>, N, []),
    ShowKids = Kind =/= <<"list">> andalso Kids0 =/= [],
    Href = loc_href(PageBase, Path, Mode),
    Node = [{name, maps:get(<<"name">>, N)},
            {is_link, true},
            {href, Href},
            {selected, Path =:= Selected},
            {open, Depth =< 0 orelse path_open(Path, Selected)},
            {has_kids, ShowKids},
            {config, maps:get(<<"config">>, N, false)},
            {kind_label, kind_label(Kind)}],
    KidsHtml = case ShowKids of
                   true -> render_nodes(Kids0, Selected, PageBase, Depth + 1, Mode);
                   false -> <<>>
               end,
    render_tree_node(Node, KidsHtml).

render_tree_node(Node, KidsHtml) ->
    tpl(ems_ui_tree_node_dtl,
        [{node, Node}, {children_html, html(KidsHtml)}]).

kind_label(<<"leaf">>) -> <<>>;
kind_label(<<"leaf-list">>) -> <<"leaf-list">>;
kind_label(Kind) -> Kind.

path_open(Path, Selected) when Path =:= Selected ->
    true;
path_open(Path, Selected) ->
    Prefix = <<Path/binary, $/>>,
    byte_size(Selected) >= byte_size(Prefix)
        andalso binary:part(Selected, 0, byte_size(Prefix)) =:= Prefix.

parse_mode(<<"oper">>) -> oper;
parse_mode(<<"state">>) -> oper;
parse_mode(_) -> config.

mode_bin(oper) -> <<"oper">>;
mode_bin(config) -> <<"config">>.

other_mode(config) -> oper;
other_mode(oper) -> config.

infer_mode(<<>>, _) ->
    config;
infer_mode(Path, Mods) ->
    case find_node(Path, Mods) of
        #{<<"config">> := false} -> oper;
        _ -> config
    end.

filter_modules(Mods, Mode) ->
    [M#{<<"children">> => Kids}
     || M <- Mods,
        Kids <- [filter_nodes(maps:get(<<"children">>, M, []), Mode)],
        Kids =/= []].

filter_nodes(Nodes, Mode) ->
    lists:filtermap(
      fun(N) ->
              case node_in_mode(N, Mode) of
                  false -> false;
                  true -> {true, keep_node(N, Mode)}
              end
      end, Nodes).

keep_node(N, Mode) ->
    Kids0 = maps:get(<<"children">>, N, []),
    Kids = case maps:get(<<"kind">>, N, undefined) of
               <<"list">> ->
                   Keys = maps:get(<<"key_names">>, N, []),
                   lists:filtermap(
                     fun(C) ->
                             Keep = lists:member(maps:get(<<"name">>, C), Keys)
                                 orelse node_in_mode(C, Mode),
                             case Keep of
                                 false -> false;
                                 true -> {true, keep_node(C, Mode)}
                             end
                     end, Kids0);
               _ ->
                   filter_nodes(Kids0, Mode)
           end,
    N#{<<"children">> => Kids}.

node_in_mode(N, Mode) ->
    case maps:get(<<"kind">>, N, undefined) of
        Kind when Kind =:= <<"leaf">>; Kind =:= <<"leaf-list">> ->
            node_is_mode(N, Mode);
        _ ->
            node_is_mode(N, Mode)
                orelse lists:any(fun(C) -> node_in_mode(C, Mode) end,
                                 maps:get(<<"children">>, N, []))
    end.

node_is_mode(N, config) ->
    maps:get(<<"config">>, N, false) =:= true;
node_is_mode(N, oper) ->
    maps:get(<<"config">>, N, false) =:= false.

writable(Node, config) ->
    maps:get(<<"config">>, Node, false);
writable(_Node, oper) ->
    false.

empty_tree_msg(config) -> <<"No configuration schema.">>;
empty_tree_msg(oper) -> <<"No operational schema.">>.

tree_label(config) -> <<"Configuration">>;
tree_label(oper) -> <<"Operational state">>.

empty_hint(config) -> <<"Select a configuration node.">>;
empty_hint(oper) -> <<"Select an operational node.">>.

wrong_mode_msg(config) -> <<"This node is operational.">>;
wrong_mode_msg(oper) -> <<"This node is configuration.">>.

other_mode_link(config) -> <<"Open in Config">>;
other_mode_link(oper) -> <<"Open in Operational">>.

render_mode_switch(Name, View, Path, Mods, Mode) ->
    ConfigPath = switch_path(Path, Mods, config),
    OperPath = switch_path(Path, Mods, oper),
    tpl(ems_ui_mode_switch_dtl,
        [{mode_config, Mode =:= config},
         {mode_oper, Mode =:= oper},
         {config_href, loc_href(page_base(Name, view_kind(View)), ConfigPath, config)},
         {oper_href, loc_href(page_base(Name, view_kind(View)), OperPath, oper)}]).

switch_path(Path, Mods, Mode) ->
    case find_node(Path, filter_modules(Mods, Mode)) of
        undefined -> <<>>;
        _ -> Path
    end.

%%--------------------------------------------------------------------
%% Pane / values
%%--------------------------------------------------------------------

render_pane(Name, undefined, <<>>, _Errors, _Draft, _View, Mode, _Mods) ->
    _ = Name,
    tpl(ems_ui_pane_dtl, empty_pane(Mode));
render_pane(Name, undefined, Path, Errors, _Draft, View, Mode, Mods) ->
    case find_node(Path, Mods) of
        undefined ->
            Vars = [{has_selection, true},
                    {wrong_mode, false},
                    {read_only, Mode =:= oper},
                    {name, Path},
                    {kind, <<>>},
                    {config, false},
                    {path, Path},
                    {value_html, <<>>},
                    {empty_hint, <<>>},
                    {load_error, <<"unknown path">>}],
            tpl(ems_ui_pane_dtl,
                put_text(Vars, write_error, maps:get(<<"page">>, Errors, undefined)));
        _Raw ->
            Other = other_mode(Mode),
            Vars = [{has_selection, false},
                    {wrong_mode, true},
                    {read_only, false},
                    {empty_hint, <<>>},
                    {wrong_mode_msg, wrong_mode_msg(Mode)},
                    {other_href, loc_href(page_base(Name, view_kind(View)), Path, Other)},
                    {other_link, other_mode_link(Other)}],
            tpl(ems_ui_pane_dtl, Vars)
    end;
render_pane(Name, Node, _Path, Errors, Draft, View, Mode, _Mods) ->
    Return = maps:get(<<"path">>, Node),
    {LoadErr, Value, Etag} = load_value(Name, Node),
    ValueHtml = case LoadErr of
                    undefined ->
                        render_value(Name, Node, Value, Return, Return, Etag,
                                     Errors, Draft, View, Mode);
                    _ ->
                        <<>>
                end,
    Vars = [{has_selection, true},
            {wrong_mode, false},
            {read_only, Mode =:= oper},
            {name, maps:get(<<"name">>, Node)},
            {kind, maps:get(<<"kind">>, Node)},
            {config, maps:get(<<"config">>, Node, false)},
            {path, Return},
            {empty_hint, <<>>},
            {value_html, html(ValueHtml)}],
    Vars1 = put_text(Vars, desc, nonempty(maps:get(<<"desc">>, Node, undefined))),
    Vars2 = put_text(Vars1, load_error, LoadErr),
    Vars3 = put_text(Vars2, write_error, maps:get(<<"page">>, Errors, undefined)),
    tpl(ems_ui_pane_dtl, Vars3).

empty_pane(Mode) ->
    [{has_selection, false},
     {wrong_mode, false},
     {read_only, false},
     {empty_hint, empty_hint(Mode)}].

load_value(Name, Node) ->
    Path = maps:get(<<"path">>, Node),
    case mgmtd_ems:get(Name, Path) of
        {ok, 200, Hdrs, Body} ->
            case mgmtd_ems_json:decode(Body) of
                {ok, Map} ->
                    {undefined, unwrap(Map, Node), etag_bin(Hdrs)};
                {error, _} ->
                    {<<"invalid JSON from node">>, undefined, etag_bin(Hdrs)}
            end;
        {ok, 404, Hdrs, _} ->
            {undefined, empty_value(Node), etag_bin(Hdrs)};
        {ok, S, _, _} when S =:= 401; S =:= 403 ->
            {<<"authentication required">>, undefined, <<>>};
        {ok, _, _, Body} ->
            {err_msg(hd(mgmtd_ems_restconf:errors(Body) ++ [<<"read failed">>])),
             undefined, <<>>};
        {error, _} ->
            {<<"node unreachable">>, undefined, <<>>}
    end.

etag_bin(Hdrs) ->
    case mgmtd_ems_restconf:etag(Hdrs) of
        undefined -> <<>>;
        S -> list_to_binary(S)
    end.

empty_value(#{<<"kind">> := <<"list">>}) -> [];
empty_value(#{<<"kind">> := <<"container">>}) -> #{};
empty_value(_) -> undefined.

unwrap(Data, Node) when is_map(Data) ->
    case first_present(Data, [maps:get(<<"qname">>, Node),
                              maps:get(<<"json_name">>, Node),
                              maps:get(<<"name">>, Node)]) of
        undefined -> Data;
        Val -> Val
    end;
unwrap(Data, _) ->
    Data.

render_value(Name, Node, Value, ResourcePath, Return, Etag, Errors, Draft, View, Mode) ->
    case maps:get(<<"kind">>, Node) of
        <<"leaf">> ->
            render_leaf(Name, Node, Value, ResourcePath, Return, Etag, Errors, View, Mode);
        <<"leaf-list">> ->
            render_leaf(Name, Node, Value, ResourcePath, Return, Etag, Errors, View, Mode);
        <<"list">> ->
            render_list(Name, Node, Value, Return, Etag, Errors, Draft, View, Mode);
        <<"container">> ->
            render_container(Name, Node, Value, ResourcePath, Return, Etag, Errors, Draft, View, Mode);
        _ ->
            <<>>
    end.

render_leaf(Name, Node, Value, ResourcePath, Return, Etag, Errors, View, Mode) ->
    CanWrite = writable(Node, Mode),
    Draft = draft_text(Node, Value),
    InputHtml = tpl(ems_ui_input_dtl, [{input, input_vars(<<"value">>, Node, Draft)}]),
    Vars = [{can_write, CanWrite},
            {ui_base, ui_base(Name)},
            {path, ResourcePath},
            {etag, Etag},
            {return_path, Return},
            {view, View},
            {mode, mode_bin(Mode)},
            {input_html, html(InputHtml)},
            {display, format_scalar(Value)}],
    tpl(ems_ui_leaf_dtl, put_text(Vars, error, maps:get(ResourcePath, Errors, undefined))).

render_container(Name, Node, Value, ResourcePath, Return, Etag, Errors, Draft, View, Mode) ->
    Kids = maps:get(<<"children">>, Node, []),
    Rows = [kv_row(Name, C, child_value(Value, C),
                   child_path(ResourcePath, maps:get(<<"name">>, C)),
                   Return, Etag, Errors, Draft, View, Mode)
            || C <- Kids],
    tpl(ems_ui_container_dtl,
        [{empty, Kids =:= []}, {rows_html, html(Rows)}]).

render_list(Name, Node, Value, Return, Etag, Errors, Draft, View, Mode) ->
    Rows = as_array(Value),
    CanWrite = writable(Node, Mode),
    Items = [render_list_item(Name, Node, Row, Return, Etag, Errors, View, Mode)
             || Row <- Rows],
    DraftHtml = render_draft(Node, <<"item">>, Draft, Errors),
    Vars = [{empty, Rows =:= []},
            {items_html, html(Items)},
            {can_write, CanWrite},
            {ui_base, ui_base(Name)},
            {path, maps:get(<<"path">>, Node)},
            {etag, Etag},
            {return_path, Return},
            {view, View},
            {mode, mode_bin(Mode)},
            {name, maps:get(<<"name">>, Node)},
            {draft_html, html(DraftHtml)}],
    tpl(ems_ui_list_dtl, put_text(Vars, add_error, maps:get(<<"add">>, Errors, undefined))).

render_list_item(Name, Node, Row, Return, Etag, Errors, View, Mode) ->
    Keys = maps:get(<<"key_names">>, Node, []),
    KeyVals = [raw_key(child_value(Row, find_child(Node, K))) || K <- Keys],
    Inst = keyed_path(maps:get(<<"path">>, Node), KeyVals),
    Title = join_nonempty(KeyVals, <<" · "/utf8>>),
    ValueFields = [C || C <- leaf_columns(Node),
                        not lists:member(maps:get(<<"name">>, C), Keys)],
    Fields = [kv_row(Name, C, child_value(Row, C),
                     child_path(Inst, maps:get(<<"name">>, C)),
                     Return, Etag, Errors, #{}, View, Mode)
              || C <- ValueFields],
    Nested = [nested_block(Name, C, child_value(Row, C),
                           child_path(Inst, maps:get(<<"name">>, C)),
                           Return, Etag, Errors, View, Mode)
              || C <- nested_columns(Node)],
    Vars = [{title, Title},
            {can_write, writable(Node, Mode)},
            {ui_base, ui_base(Name)},
            {instance_path, Inst},
            {etag, Etag},
            {return_path, Return},
            {view, View},
            {mode, mode_bin(Mode)},
            {fields_html, html(Fields)},
            {nested_html, html(Nested)}],
    KeyLegend = case Keys of
                    [_ , _ | _] -> join_nonempty(Keys, <<" · "/utf8>>);
                    _ -> <<>>
                end,
    tpl(ems_ui_list_item_dtl, put_text(Vars, key_legend, KeyLegend)).

kv_row(Name, Child, Val, ResourcePath, Return, Etag, Errors, Draft, View, Mode) ->
    Kind = maps:get(<<"kind">>, Child),
    Inner = case Kind of
                <<"leaf">> ->
                    render_leaf(Name, Child, Val, ResourcePath, Return, Etag, Errors, View, Mode);
                <<"leaf-list">> ->
                    render_leaf(Name, Child, Val, ResourcePath, Return, Etag, Errors, View, Mode);
                _ ->
                    render_value(Name, Child, Val, ResourcePath, Return, Etag, Errors, Draft, View, Mode)
            end,
    tpl(ems_ui_kv_row_dtl,
        [{label, maps:get(<<"name">>, Child)},
         {oper, false},
         {value_html, html(Inner)}]).

nested_block(Name, Child, Val, ResourcePath, Return, Etag, Errors, View, Mode) ->
    Inner = render_value(Name, Child, Val, ResourcePath, Return, Etag, Errors, #{}, View, Mode),
    tpl(ems_ui_nested_dtl,
        [{name, maps:get(<<"name">>, Child)},
         {value_html, html(Inner)}]).

render_draft(Node, Prefix, Draft, Errors) ->
    [render_draft_field(F, Prefix, Draft, Errors) || F <- draft_fields(Node)].

render_draft_field(Field, Prefix, Draft, Errors) ->
    Name = maps:get(<<"name">>, Field),
    InputName = <<Prefix/binary, $., Name/binary>>,
    case maps:get(<<"kind">>, Field) of
        <<"container">> ->
            Nested = as_map(nested_get(Draft, Name)),
            Children = render_draft(Field, InputName, Nested, Errors),
            tpl(ems_ui_draft_field_dtl,
                [{is_container, true},
                 {label, Name},
                 {children_html, html(Children)}]);
        _ ->
            Value = case nested_get(Draft, Name) of
                        undefined -> default_draft(Field);
                        V -> to_bin(V)
                    end,
            InputHtml = tpl(ems_ui_input_dtl,
                            [{input, input_vars(InputName, Field, Value)}]),
            Vars = [{is_container, false},
                    {label, Name},
                    {input_html, html(InputHtml)}],
            tpl(ems_ui_draft_field_dtl,
                put_text(Vars, error, maps:get(InputName, Errors, undefined)))
    end.

draft_fields(Node) ->
    Keys = maps:get(<<"key_names">>, Node, []),
    Kids = config_children(Node),
    KeyNodes = [C || K <- Keys, C <- [find_child(Node, K)], C =/= undefined],
    RestLeaves = [C || C <- Kids,
                       is_leafish(C),
                       not lists:member(maps:get(<<"name">>, C), Keys)],
    Containers = [C || C <- Kids, maps:get(<<"kind">>, C) =:= <<"container">>],
    KeyNodes ++ RestLeaves ++ Containers.

config_children(Node) ->
    [C || C <- maps:get(<<"children">>, Node, []),
          maps:get(<<"config">>, C, false)].

leaf_columns(Node) ->
    Keys = maps:get(<<"key_names">>, Node, []),
    Leaves = [C || C <- maps:get(<<"children">>, Node, []), is_leafish(C)],
    Keyed = [C || K <- Keys, C <- [find_child(Node, K)], C =/= undefined],
    Rest = [C || C <- Leaves, not lists:member(maps:get(<<"name">>, C), Keys)],
    Keyed ++ Rest.

nested_columns(Node) ->
    [C || C <- maps:get(<<"children">>, Node, []),
          K <- [maps:get(<<"kind">>, C)],
          K =:= <<"container">> orelse K =:= <<"list">>].

is_leafish(#{<<"kind">> := <<"leaf">>}) -> true;
is_leafish(#{<<"kind">> := <<"leaf-list">>}) -> true;
is_leafish(_) -> false.

default_draft(Node) ->
    case maps:get(<<"default">>, Node, undefined) of
        undefined -> <<>>;
        Def -> draft_from_value(Def)
    end.

build_item(Node, Draft, Prefix) ->
    build_kids(draft_fields(Node), Node, as_map(Draft), Prefix, #{}).

build_kids([], _Node, _Draft, _Prefix, Acc) ->
    {ok, Acc};
build_kids([C | Rest], Node, Draft, Prefix, Acc) ->
    Name = maps:get(<<"name">>, C),
    Json = maps:get(<<"json_name">>, C),
    InputName = <<Prefix/binary, $., Name/binary>>,
    Keys = maps:get(<<"key_names">>, Node, []),
    case maps:get(<<"kind">>, C) of
        <<"container">> ->
            NestedDraft = as_map(nested_get(Draft, Name)),
            case build_item(C, NestedDraft, InputName) of
                {error, _} = Err ->
                    Err;
                {ok, Nested} when map_size(Nested) =:= 0 ->
                    build_kids(Rest, Node, Draft, Prefix, Acc);
                {ok, Nested} ->
                    build_kids(Rest, Node, Draft, Prefix, Acc#{Json => Nested})
            end;
        <<"leaf-list">> ->
            Raw = to_bin(nested_get(Draft, Name)),
            case parse_snapshot_leaf_list(C, Raw) of
                {error, Msg} ->
                    {error, #{InputName => Msg}};
                {ok, []} ->
                    case required(C, Keys) of
                        true -> {error, #{InputName => <<"required">>}};
                        false -> build_kids(Rest, Node, Draft, Prefix, Acc)
                    end;
                {ok, List} ->
                    build_kids(Rest, Node, Draft, Prefix, Acc#{Json => List})
            end;
        <<"leaf">> ->
            Raw = string:trim(to_bin(nested_get(Draft, Name))),
            case Raw of
                <<>> ->
                    case required(C, Keys) of
                        true -> {error, #{InputName => <<"required">>}};
                        false -> build_kids(Rest, Node, Draft, Prefix, Acc)
                    end;
                _ ->
                    case parse_snapshot_leaf(C, Raw) of
                        {error, Msg} ->
                            {error, #{InputName => Msg}};
                        {ok, Val} ->
                            build_kids(Rest, Node, Draft, Prefix, Acc#{Json => Val})
                    end
            end;
        _ ->
            build_kids(Rest, Node, Draft, Prefix, Acc)
    end.

required(C, Keys) ->
    lists:member(maps:get(<<"name">>, C), Keys)
        orelse maps:get(<<"mandatory">>, C, false) =:= true.

parse_snapshot_leaf(Node, Raw) ->
    Type = maps:get(<<"type">>, Node, #{}),
    parse_base(maps:get(<<"base">>, Type, <<"string">>),
               maps:get(<<"name">>, Node), Raw).

parse_snapshot_leaf_list(Node, Raw) ->
    Lines = [L || L <- binary:split(Raw, <<"\n">>, [global]),
                  string:trim(L) =/= <<>>],
    parse_lines(Lines, Node, []).

parse_lines([], _Node, Acc) ->
    {ok, lists:reverse(Acc)};
parse_lines([L | Rest], Node, Acc) ->
    case parse_snapshot_leaf(Node, string:trim(L)) of
        {ok, V} -> parse_lines(Rest, Node, [V | Acc]);
        {error, _} = Err -> Err
    end.

parse_base(<<"boolean">>, _Name, <<"true">>) -> {ok, true};
parse_base(<<"boolean">>, _Name, <<"false">>) -> {ok, false};
parse_base(<<"boolean">>, _Name, _) -> {error, <<"boolean must be true or false">>};
parse_base(Base, Name, Bin) ->
    case is_int_base(Base) of
        true -> parse_int(Bin);
        false when Base =:= <<"decimal64">> -> parse_number(Name, Bin);
        false -> {ok, Bin}
    end.

parse_int(Bin) ->
    try binary_to_integer(string:trim(Bin)) of
        N -> {ok, N}
    catch
        _:_ -> {error, <<"expected an integer">>}
    end.

parse_number(Name, Bin) ->
    Text = string:trim(Bin),
    try binary_to_integer(Text) of
        N -> {ok, N}
    catch
        _:_ ->
            try binary_to_float(Text) of
                F -> {ok, F}
            catch
                _:_ -> {error, <<Name/binary, " expected a number">>}
            end
    end.

collect_item(Qs) ->
    lists:foldl(
      fun({<<"item.", Rest/binary>>, Val}, Acc) ->
              put_dotted(Acc, binary:split(Rest, <<".">>, [global]), Val);
         (_, Acc) ->
              Acc
      end, #{}, Qs).

put_dotted(Map, [K], Val) ->
    Map#{K => Val};
put_dotted(Map, [K | Rest], Val) ->
    Child = as_map(maps:get(K, Map, #{})),
    Map#{K => put_dotted(Child, Rest, Val)}.

find_node(<<>>, _) ->
    undefined;
find_node(Path, Modules) ->
    find_in(Path, lists:append([maps:get(<<"children">>, M, []) || M <- Modules])).

find_in(_Path, []) ->
    undefined;
find_in(Path, [N | Rest]) ->
    case maps:get(<<"path">>, N, undefined) of
        Path ->
            N;
        _ ->
            case find_in(Path, maps:get(<<"children">>, N, [])) of
                undefined -> find_in(Path, Rest);
                Found -> Found
            end
    end.

find_child(Node, Name0) ->
    Name = to_bin(Name0),
    case [C || C <- maps:get(<<"children">>, Node, []),
               maps:get(<<"name">>, C) =:= Name] of
        [C | _] -> C;
        [] -> undefined
    end.

child_value(_Parent, undefined) ->
    undefined;
child_value(Parent, Child) when is_map(Parent) ->
    first_present(Parent, [maps:get(<<"json_name">>, Child, undefined),
                           maps:get(<<"name">>, Child, undefined),
                           maps:get(<<"qname">>, Child, undefined)]);
child_value(_, _) ->
    undefined.

first_present(_Map, []) ->
    undefined;
first_present(Map, [undefined | Rest]) ->
    first_present(Map, Rest);
first_present(Map, [K | Rest]) ->
    case maps:find(K, Map) of
        {ok, V} -> V;
        error -> first_present(Map, Rest)
    end.

child_path(Parent, Name) ->
    P = strip_slash(Parent),
    <<P/binary, $/, Name/binary>>.

keyed_path(ListPath, Keys) ->
    Enc = lists:join($,, [uri_quote(to_bin(K)) || K <- Keys]),
    iolist_to_binary([strip_slash(ListPath), $=, Enc]).

uri_quote(Bin) when is_binary(Bin) ->
    << <<(uri_quote_byte(C))/binary>> || <<C>> <= Bin >>.

uri_quote_byte(C) when C >= $a, C =< $z -> <<C>>;
uri_quote_byte(C) when C >= $A, C =< $Z -> <<C>>;
uri_quote_byte(C) when C >= $0, C =< $9 -> <<C>>;
uri_quote_byte(C) when C =:= $-; C =:= $.; C =:= $_; C =:= $~ -> <<C>>;
uri_quote_byte(C) ->
    <<$%, (hex_digit(C bsr 4)), (hex_digit(C band 15))>>.

hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N) -> $A + (N - 10).

strip_slash(P) ->
    S = byte_size(P),
    case S > 0 andalso binary:at(P, S - 1) =:= $/ of
        true -> binary:part(P, 0, S - 1);
        false -> P
    end.

as_array(L) when is_list(L) -> L;
as_array(_) -> [].

as_map(M) when is_map(M) -> M;
as_map(_) -> #{}.

nested_get(Map, Key) when is_map(Map) ->
    maps:get(Key, Map, undefined);
nested_get(_, _) ->
    undefined.

input_vars(Name, Node, ValueBin) ->
    Type = maps:get(<<"type">>, Node, #{}),
    Base = maps:get(<<"base">>, Type, <<"string">>),
    EnumNames = [enum_name(E) || E <- maps:get(<<"enum">>, Type, [])],
    Kind = maps:get(<<"kind">>, Node),
    Vars = [{name, Name},
            {value, ValueBin},
            {is_bool, Base =:= <<"boolean">>},
            {is_enum, EnumNames =/= []},
            {is_textarea, Kind =:= <<"leaf-list">>},
            {is_number, EnumNames =:= [] andalso (is_int_base(Base) orelse Base =:= <<"decimal64">>)},
            {true_selected, ValueBin =:= <<"true">>},
            {false_selected, ValueBin =:= <<"false">>},
            {enums, [[{name, N}, {selected, N =:= ValueBin}] || N <- EnumNames]}],
    put_text(Vars, placeholder, default_placeholder(Node)).

default_placeholder(Node) ->
    case maps:get(<<"default">>, Node, undefined) of
        undefined -> undefined;
        Def -> draft_from_value(Def)
    end.

enum_name(#{<<"name">> := N}) -> N;
enum_name(B) when is_binary(B) -> B;
enum_name(L) when is_list(L) -> to_bin(L).

draft_text(#{<<"kind">> := <<"leaf-list">>}, Value) ->
    case Value of
        L when is_list(L) -> join_nonempty([draft_from_value(V) || V <- L], <<"\n">>);
        _ -> <<>>
    end;
draft_text(_, Value) ->
    draft_from_value(Value).

draft_from_value(undefined) -> <<>>;
draft_from_value(null) -> <<>>;
draft_from_value(true) -> <<"true">>;
draft_from_value(false) -> <<"false">>;
draft_from_value(N) when is_integer(N) -> integer_to_binary(N);
draft_from_value(N) when is_float(N) -> float_to_binary(N, [{decimals, 6}, compact]);
draft_from_value(B) when is_binary(B) -> B;
draft_from_value(L) when is_list(L) ->
    case io_lib:printable_unicode_list(L) of
        true -> unicode:characters_to_binary(L);
        false -> iolist_to_binary(mgmtd_ems_json:encode(L))
    end;
draft_from_value(Other) ->
    iolist_to_binary(io_lib:format("~p", [Other])).

format_scalar(undefined) -> <<"—"/utf8>>;
format_scalar(null) -> <<"—"/utf8>>;
format_scalar(<<>>) -> <<"\"\"">>;
format_scalar(true) -> <<"true">>;
format_scalar(false) -> <<"false">>;
format_scalar(N) when is_integer(N) -> integer_to_binary(N);
format_scalar(N) when is_float(N) -> float_to_binary(N, [{decimals, 6}, compact]);
format_scalar(B) when is_binary(B) -> B;
format_scalar(L) when is_list(L) ->
    case io_lib:printable_unicode_list(L) of
        true -> unicode:characters_to_binary(L);
        false -> iolist_to_binary(mgmtd_ems_json:encode(L))
    end;
format_scalar(Other) ->
    iolist_to_binary(io_lib:format("~p", [Other])).

raw_key(undefined) -> <<>>;
raw_key(N) when is_integer(N) -> integer_to_binary(N);
raw_key(B) when is_binary(B) -> B;
raw_key(L) when is_list(L) -> unicode:characters_to_binary(L);
raw_key(A) when is_atom(A) -> atom_to_binary(A, utf8);
raw_key(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

join_nonempty(Parts, Sep) ->
    case [to_bin(P) || P <- Parts, to_bin(P) =/= <<>>] of
        [] -> <<"item">>;
        [One] -> One;
        [First | Rest] ->
            iolist_to_binary([First | [[Sep, P] || P <- Rest]])
    end.

is_int_base(B) ->
    lists:member(B, [<<"uint8">>, <<"uint16">>, <<"uint32">>, <<"uint64">>,
                     <<"int8">>, <<"int16">>, <<"int32">>, <<"int64">>,
                     <<"integer">>, <<"inet:port-number">>]).

err_msg(#{<<"error-message">> := M, <<"error-tag">> := T}) ->
    iolist_to_binary([T, <<": ">>, M]);
err_msg(#{<<"error-message">> := M}) ->
    M;
err_msg(#{<<"error-tag">> := T}) ->
    T;
err_msg(#{message := M, tag := T}) ->
    iolist_to_binary([to_bin(T), <<": ">>, to_bin(M)]);
err_msg(#{message := M}) ->
    to_bin(M);
err_msg(B) when is_binary(B) ->
    B;
err_msg(L) when is_list(L) ->
    to_bin(L);
err_msg(_) ->
    <<"error">>.

nonempty(undefined) -> undefined;
nonempty(<<>>) -> undefined;
nonempty("") -> undefined;
nonempty(S) -> to_bin(S).

put_text(List, _K, undefined) -> List;
put_text(List, _K, <<>>) -> List;
put_text(List, K, V) -> [{K, V} | List].

qs_val(Qs, Key) ->
    qs_val(Qs, Key, <<>>).

qs_val(Qs, Key, Default) ->
    case lists:keyfind(Key, 1, Qs) of
        {_, V} -> V;
        false -> Default
    end.

empty_to_undef(<<>>) -> undefined;
empty_to_undef(B) -> binary_to_list(B).

parse_port(Bin) ->
    try binary_to_integer(string:trim(Bin)) of
        N when N > 0, N < 65536 -> N;
        _ -> 8008
    catch
        _:_ -> 8008
    end.

to_bin(undefined) -> <<>>;
to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(N) when is_integer(N) -> integer_to_binary(N);
to_bin(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

%%--------------------------------------------------------------------
%% Templates
%%--------------------------------------------------------------------

-spec compile() -> ok | {error, term()}.
compile() ->
    case code:priv_dir(mgmtd_ems) of
        {error, _} = Err ->
            Err;
        Priv ->
            Dir = filename:join(Priv, "templates"),
            _ = application:ensure_all_started(compiler),
            _ = application:ensure_all_started(erlydtl),
            Opts = [{out_dir, false}, {doc_root, Dir}, {auto_escape, true}],
            compile_files(
              ["ems_ui_input.dtl",
               "ems_ui_tree_node.dtl",
               "ems_ui_kv_row.dtl",
               "ems_ui_leaf.dtl",
               "ems_ui_container.dtl",
               "ems_ui_nested.dtl",
               "ems_ui_draft_field.dtl",
               "ems_ui_list_item.dtl",
               "ems_ui_list.dtl",
               "ems_ui_pane.dtl",
               "ems_ui_mode_switch.dtl",
               "ems_ui_content.dtl",
               "ems_ui_node.dtl",
               "ems_ui_index.dtl"],
              Dir, Opts)
    end.

ensure_compiled() ->
    case code:ensure_loaded(ems_ui_content_dtl) of
        {module, _} ->
            ok;
        {error, _} ->
            case compile() of
                ok -> ok;
                {error, Reason} -> error({mgmtd_ems_ui_templates, Reason})
            end
    end.

compile_files([], _Dir, _Opts) ->
    ok;
compile_files([F | Rest], Dir, Opts) ->
    File = filename:join(Dir, F),
    Base = binary_to_list(iolist_to_binary(filename:basename(F, ".dtl"))),
    Mod = list_to_atom(Base ++ "_dtl"),
    case erlydtl:compile_file(File, Mod, Opts) of
        {ok, _} -> compile_files(Rest, Dir, Opts);
        {ok, _, _} -> compile_files(Rest, Dir, Opts);
        {ok, _, _, _} -> compile_files(Rest, Dir, Opts);
        error -> {error, {compile_failed, F}};
        {error, Errs, Warns} -> {error, {F, Errs, Warns}}
    end.

tpl(Mod, Vars) ->
    case Mod:render(Vars) of
        {ok, Io} -> iolist_to_binary(Io);
        {ok, Io, _} -> iolist_to_binary(Io)
    end.

html(Bin) when is_binary(Bin) -> Bin;
html(Io) -> iolist_to_binary(Io).
