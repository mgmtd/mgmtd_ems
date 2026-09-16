%%%-------------------------------------------------------------------
%% @doc Cowboy callback for the EMS HTML UI.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_ems_ui_handler).

-export([init/2]).

init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    Req = handle(Method, State, Req0),
    {ok, Req, State}.

handle(<<"GET">>, inventory, Req) ->
    mgmtd_ems_ui:inventory(Req);
handle(<<"HEAD">>, inventory, Req) ->
    mgmtd_ems_ui:inventory(Req);
handle(<<"POST">>, add_node, Req) ->
    mgmtd_ems_ui:add_node(Req);
handle(<<"POST">>, remove_node, Req) ->
    mgmtd_ems_ui:remove_node(Req);
handle(<<"GET">>, node, Req) ->
    mgmtd_ems_ui:http_get(index, Req);
handle(<<"HEAD">>, node, Req) ->
    mgmtd_ems_ui:http_get(index, Req);
handle(<<"GET">>, content, Req) ->
    mgmtd_ems_ui:http_get(content, Req);
handle(<<"HEAD">>, content, Req) ->
    mgmtd_ems_ui:http_get(content, Req);
handle(<<"POST">>, save, Req) ->
    mgmtd_ems_ui:http_post(save, Req);
handle(<<"POST">>, add, Req) ->
    mgmtd_ems_ui:http_post(add, Req);
handle(<<"POST">>, delete, Req) ->
    mgmtd_ems_ui:http_post(delete, Req);
handle(<<"OPTIONS">>, State, Req)
  when State =:= inventory; State =:= node; State =:= content ->
    cowboy_req:reply(200, #{<<"allow">> => <<"GET, HEAD, OPTIONS">>}, <<>>, Req);
handle(<<"OPTIONS">>, _, Req) ->
    cowboy_req:reply(200, #{<<"allow">> => <<"POST, OPTIONS">>}, <<>>, Req);
handle(_, State, Req)
  when State =:= inventory; State =:= node; State =:= content ->
    cowboy_req:reply(405, #{<<"allow">> => <<"GET, HEAD, OPTIONS">>}, <<>>, Req);
handle(_, _, Req) ->
    cowboy_req:reply(405, #{<<"allow">> => <<"POST, OPTIONS">>}, <<>>, Req).
