%%%-------------------------------------------------------------------
%% @doc Southbound RESTCONF client (RFC 8040) over httpc.
%%
%% `Path` is either:
%%
%% - absolute from the host (`"/restconf/data"`, `"/.well-known/host-meta"`)
%% - a suffix under `/restconf/` (`"data"`, `"data/ex:foo"`)
%%
%% `Opts`:
%%
%% - `accept` / `content_type` — media types (default `yang-data+json`)
%% - `query` — list or map of query string pairs (`with-defaults`, `insert`)
%% - `etag` — sent as `If-Match`
%% - `timeout` — httpc timeout in ms (default 5000)
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_ems_restconf).

-export([request/3, request/4, request/5, url/2, url/3]).
-export([header/2, etag/1, decode_json/1, errors/1]).

-export_type([opts/0, result/0]).

-include("mgmtd_ems.hrl").

-define(TIMEOUT, 5000).
-define(YANG_JSON, "application/yang-data+json").

-type opts() :: #{
                  accept => iodata(),
                  content_type => iodata(),
                  query => [{iodata(), iodata()}] | map(),
                  etag => iodata() | undefined,
                  timeout => pos_integer()
                 }.

-type result() :: {ok, pos_integer(), [{string(), string()}], binary()}
                | {error, term()}.

-spec url(map(), iodata()) -> string().
url(Node, Path) ->
    url(Node, Path, []).

-spec url(map(), iodata(), [{iodata(), iodata()}] | map()) -> string().
url(Node, Path, Query) ->
    Scheme = case maps:get(tls, Node, false) of
                 true -> "https";
                 false -> "http"
             end,
    Host = host_to_list(maps:get(host, Node)),
    Port = integer_to_list(maps:get(port, Node, ?MGMTD_EMS_DEFAULT_PORT)),
    Base = Scheme ++ "://" ++ bracket_host(Host) ++ ":" ++ Port ++ path(Path),
    append_query(Base, Query).

-spec request(map(), atom(), iodata()) -> result().
request(Node, Method, Path) ->
    request(Node, Method, Path, undefined, #{}).

-spec request(map(), atom(), iodata(), iodata() | map() | undefined) -> result().
request(Node, Method, Path, Body) ->
    request(Node, Method, Path, Body, #{}).

-spec request(map(), atom(), iodata(), iodata() | map() | undefined, opts()) ->
          result().
request(Node, Method, Path, Body, Opts) when is_map(Opts) ->
    _ = application:ensure_all_started(inets),
    maybe_start_tls(Node),
    Url = url(Node, Path, maps:get(query, Opts, [])),
    Headers = request_headers(Node, Opts),
    HttpOpts = [{timeout, maps:get(timeout, Opts, ?TIMEOUT)}],
    HttpcOpts = [{body_format, binary}],
    Req = httpc_req(Method, Url, Headers, Body, Opts),
    case httpc:request(Method, Req, HttpOpts, HttpcOpts) of
        {ok, {{_Http, Status, _Reason}, RespHdrs, RespBody}} ->
            {ok, Status, normalize_headers(RespHdrs), iolist_to_binary(RespBody)};
        {ok, {Status, RespBody}} when is_integer(Status) ->
            {ok, Status, [], iolist_to_binary(RespBody)};
        {error, Reason} ->
            {error, Reason}
    end.

-spec header(string() | binary(), [{string(), string()}]) -> string() | undefined.
header(Name, Headers) ->
    Want = string:lowercase(to_list(Name)),
    case lists:dropwhile(
           fun({K, _}) -> string:lowercase(to_list(K)) =/= Want end,
           Headers) of
        [{_, V} | _] ->
            to_list(V);
        [] ->
            undefined
    end.

-spec etag([{string(), string()}]) -> string() | undefined.
etag(Headers) ->
    header("etag", Headers).

-spec decode_json(binary()) -> {ok, term()} | {error, term()}.
decode_json(Body) ->
    mgmtd_ems_json:decode(Body).

%% RFC 8040 error list from a JSON body, or `[]` if none.
-spec errors(binary() | term()) -> [map()].
errors(Body) when is_binary(Body) ->
    case decode_json(Body) of
        {ok, Term} ->
            errors(Term);
        {error, _} ->
            []
    end;
errors(#{<<"ietf-restconf:errors">> := #{<<"error">> := List}})
  when is_list(List) ->
    List;
errors(_) ->
    [].

httpc_req(Method, Url, Headers, Body, Opts)
  when Method =:= put; Method =:= patch; Method =:= post ->
    CT = to_list(maps:get(content_type, Opts, ?YANG_JSON)),
    {Url, Headers, CT, encode_body(Body)};
httpc_req(_Method, Url, Headers, _Body, _Opts) ->
    {Url, Headers}.

request_headers(Node, Opts) ->
    Accept = to_list(maps:get(accept, Opts, ?YANG_JSON)),
    auth_headers(Node) ++
        [{"accept", Accept}] ++
        etag_headers(maps:get(etag, Opts, undefined)).

etag_headers(undefined) ->
    [];
etag_headers("") ->
    [];
etag_headers(<<>>) ->
    [];
etag_headers(Etag) ->
    [{"if-match", to_list(Etag)}].

encode_body(undefined) ->
    <<>>;
encode_body(Map) when is_map(Map) ->
    mgmtd_ems_json:encode(Map);
encode_body(Bin) when is_binary(Bin) ->
    Bin;
encode_body(Io) ->
    iolist_to_binary(Io).

append_query(Base, Query) when Query =:= []; Query =:= #{} ->
    Base;
append_query(Base, Query) when is_map(Query) ->
    append_query(Base, maps:to_list(Query));
append_query(Base, Query) when is_list(Query) ->
    Pairs = [{to_list(K), to_list(V)} || {K, V} <- Query],
    Base ++ "?" ++ uri_string:compose_query(Pairs).

normalize_headers(Hdrs) ->
    [{to_list(K), to_list(V)} || {K, V} <- Hdrs].

path(Path) ->
    S = to_list(Path),
    case S of
        "/" ++ _ ->
            S;
        "restconf/" ++ _ ->
            "/" ++ S;
        "restconf" ->
            "/restconf";
        _ ->
            "/restconf/" ++ string:trim(S, leading, "/")
    end.

auth_headers(#{user := User, password := Password})
  when User =/= undefined, Password =/= undefined ->
    Token = base64:encode_to_string(to_list(User) ++ ":" ++ to_list(Password)),
    [{"authorization", "Basic " ++ Token}];
auth_headers(_) ->
    [].

maybe_start_tls(#{tls := true}) ->
    application:ensure_all_started(ssl),
    ok;
maybe_start_tls(_) ->
    ok.

host_to_list(Host) when is_tuple(Host) ->
    inet:ntoa(Host);
host_to_list(Host) ->
    to_list(Host).

bracket_host(Host) ->
    case lists:member($:, Host) of
        true -> "[" ++ Host ++ "]";
        false -> Host
    end.

to_list(B) when is_binary(B) ->
    binary_to_list(B);
to_list(L) when is_list(L) ->
    L;
to_list(A) when is_atom(A) ->
    atom_to_list(A);
to_list(N) when is_integer(N) ->
    integer_to_list(N).
