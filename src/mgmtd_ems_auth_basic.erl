%%%-------------------------------------------------------------------
%%% @doc Form login + session cookie against a static user list.
%%%
%%% Default EMS web-UI callback. GET `/login` is the form; POST checks
%%% `{users, ...}` and sets an HttpOnly `ems_sid` cookie. Unauthenticated
%%% UI requests redirect to `/login`. `/static` stays open so the form
%%% can load CSS. Empty `users` means nobody can sign in.
%%%
%%% Passwords are plaintext in config.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_ems_auth_basic).

-export([init/1, authenticate/2, terminate/1]).

-define(COOKIE, <<"ems_sid">>).
-define(DEFAULT_TTL, 8 * 60 * 60).
-define(HTML, <<"text/html; charset=utf-8">>).

-spec init(mgmtd_ems_auth:opts()) -> {ok, map()}.
init(Opts) ->
    Users = normalize_users(proplists:get_value(users, Opts, [])),
    Ttl = case proplists:get_value(session_ttl, Opts, ?DEFAULT_TTL) of
              N when is_integer(N), N > 0 -> N;
              _ -> ?DEFAULT_TTL
          end,
    Tab = ets:new(?MODULE, [set, public]),
    {ok, #{users => Users, tab => Tab, ttl => Ttl}}.

-spec terminate(map()) -> ok.
terminate(#{tab := Tab}) ->
    ets:delete(Tab),
    ok;
terminate(_) ->
    ok.

-spec authenticate(cowboy_req:req(), map()) ->
          {ok, mgmtd_ems_auth:identity(), cowboy_req:req()} |
          {stop, cowboy_req:req()}.
authenticate(Req, State) ->
    case cowboy_req:path(Req) of
        <<"/logout">> ->
            logout(Req, State);
        <<"/logout/">> ->
            logout(Req, State);
        <<"/login">> ->
            login(Req, State);
        <<"/login/">> ->
            login(Req, State);
        Path ->
            case session(Req, State) of
                {ok, Identity} ->
                    {ok, Identity, Req};
                error ->
                    unauthenticated(Path, Req)
            end
    end.

%%--------------------------------------------------------------------
%% Login / logout
%%--------------------------------------------------------------------

login(Req, State) ->
    case cowboy_req:method(Req) of
        <<"POST">> ->
            login_post(Req, State);
        _ ->
            login_get(Req, State)
    end.

login_get(Req, State) ->
    Next = next_from_qs(Req),
    case session(Req, State) of
        {ok, _} ->
            {stop, cowboy_req:reply(302, #{<<"location">> => Next}, <<>>, Req)};
        error ->
            {stop, reply_login(Req, undefined, Next, <<>>)}
    end.

login_post(Req0, #{users := Users} = State) ->
    case cowboy_req:read_urlencoded_body(Req0) of
        {ok, Qs, Req} ->
            User = string:trim(qs_val(Qs, <<"user">>)),
            Pass = qs_val(Qs, <<"password">>),
            Next = safe_next(qs_val(Qs, <<"next">>)),
            case check(User, Pass, Users) of
                {ok, Identity} ->
                    Req1 = drop_session(Req, State),
                    Req2 = create_session(Identity, Req1, State),
                    {stop, cowboy_req:reply(
                             302, #{<<"location">> => Next}, <<>>, Req2)};
                error ->
                    {stop, reply_login(Req, <<"Invalid username or password">>,
                                       Next, User)}
            end;
        {error, _} ->
            {stop, reply_login(Req0, <<"Invalid username or password">>,
                               <<"/">>, <<>>)}
    end.

logout(Req0, State) ->
    Req = drop_session(Req0, State),
    {stop, cowboy_req:reply(302, #{<<"location">> => <<"/login">>}, <<>>, Req)}.

unauthenticated(Path, Req) ->
    case is_static(Path) of
        true ->
            {ok, #{user => <<"anonymous">>, role => admin}, Req};
        false ->
            Loc = <<"/login?next=", (cow_qs:urlencode(current_path(Req)))/binary>>,
            {stop, cowboy_req:reply(302, #{<<"location">> => Loc}, <<>>, Req)}
    end.

reply_login(Req, Error, Next, User) ->
    Vars = [{css_href, <<"/static/ems_ui.css">>},
            {next, Next},
            {user, User}],
    Vars1 = case nonempty(Error) of
                undefined -> Vars;
                Msg -> [{error, Msg} | Vars]
            end,
    Body = render_login(Vars1),
    cowboy_req:reply(200, #{<<"content-type">> => ?HTML}, Body, Req).

render_login(Vars) ->
    case ems_ui_login_dtl:render(Vars) of
        {ok, Body} ->
            iolist_to_binary(Body);
        {ok, Body, _} ->
            iolist_to_binary(Body)
    end.

%%--------------------------------------------------------------------
%% Sessions
%%--------------------------------------------------------------------

session(Req, #{tab := Tab}) ->
    case lists:keyfind(?COOKIE, 1, cowboy_req:parse_cookies(Req)) of
        {_, Sid} when is_binary(Sid), Sid =/= <<>> ->
            lookup_session(Tab, Sid);
        _ ->
            error
    end.

lookup_session(Tab, Sid) ->
    Now = erlang:system_time(second),
    case ets:lookup(Tab, Sid) of
        [{Sid, Identity, Exp}] when Now < Exp ->
            {ok, Identity};
        [{Sid, _, _}] ->
            ets:delete(Tab, Sid),
            error;
        [] ->
            error
    end.

create_session(Identity, Req, #{tab := Tab, ttl := Ttl}) ->
    Sid = binary:encode_hex(crypto:strong_rand_bytes(16)),
    true = ets:insert(Tab, {Sid, Identity, erlang:system_time(second) + Ttl}),
    cowboy_req:set_resp_cookie(
      ?COOKIE, Sid, Req,
      #{path => <<"/">>, http_only => true, same_site => lax, max_age => Ttl}).

drop_session(Req, #{tab := Tab}) ->
    case lists:keyfind(?COOKIE, 1, cowboy_req:parse_cookies(Req)) of
        {_, Sid} ->
            ets:delete(Tab, Sid);
        _ ->
            ok
    end,
    cowboy_req:set_resp_cookie(
      ?COOKIE, <<>>, Req,
      #{path => <<"/">>, http_only => true, max_age => 0}).

%%--------------------------------------------------------------------
%% Users / passwords
%%--------------------------------------------------------------------

check(User, Pass, Users) ->
    Name = to_bin(User),
    case lists:keyfind(Name, 1, Users) of
        {Name, Expected, Role} ->
            case password_eq(Pass, Expected) of
                true ->
                    {ok, #{user => Name, role => Role}};
                false ->
                    error
            end;
        false ->
            _ = password_eq(Pass, <<>>),
            error
    end.

normalize_users(List) when is_list(List) ->
    lists:filtermap(fun normalize_user/1, List);
normalize_users(_) ->
    [].

normalize_user({Name, Pass}) ->
    normalize_user({Name, Pass, admin});
normalize_user({Name, Pass, Role}) when Role =:= admin; Role =:= read_only ->
    case is_name(Name) andalso is_pass(Pass) of
        true ->
            {true, {to_bin(Name), to_bin(Pass), Role}};
        false ->
            false
    end;
normalize_user(_) ->
    false.

password_eq(Given, Expected) ->
    crypto:bytes_to_integer(
      crypto:exor(secret_hash(Given), secret_hash(Expected))) =:= 0.

secret_hash(Value) ->
    crypto:hash(sha256, to_bin(Value)).

is_name(Name) when is_list(Name), Name =/= [] ->
    true;
is_name(Name) when is_binary(Name), Name =/= <<>> ->
    true;
is_name(_) ->
    false.

is_pass(Pass) when is_list(Pass), Pass =/= [] ->
    true;
is_pass(Pass) when is_binary(Pass), Pass =/= <<>> ->
    true;
is_pass(_) ->
    false.

%%--------------------------------------------------------------------
%% Paths / form
%%--------------------------------------------------------------------

is_static(<<"/static/", _/binary>>) ->
    true;
is_static(_) ->
    false.

current_path(Req) ->
    Path = cowboy_req:path(Req),
    case cowboy_req:qs(Req) of
        <<>> ->
            safe_next(Path);
        Qs ->
            safe_next(<<Path/binary, $?, Qs/binary>>)
    end.

next_from_qs(Req) ->
    safe_next(qs_val(cowboy_req:parse_qs(Req), <<"next">>)).

safe_next(<<"/login", _/binary>>) ->
    <<"/">>;
safe_next(<<"/logout", _/binary>>) ->
    <<"/">>;
safe_next(<<$/, _/binary>> = Path) ->
    case Path of
        <<"//", _/binary>> ->
            <<"/">>;
        _ ->
            case binary:match(Path, [<<":">>, <<"\\">>]) of
                nomatch -> Path;
                _ -> <<"/">>
            end
    end;
safe_next(_) ->
    <<"/">>.

qs_val(Qs, Key) ->
    case lists:keyfind(Key, 1, Qs) of
        {_, V} when is_binary(V) -> V;
        {_, V} when is_list(V) -> unicode:characters_to_binary(V);
        _ -> <<>>
    end.

nonempty(<<>>) ->
    undefined;
nonempty(undefined) ->
    undefined;
nonempty(Bin) ->
    Bin.

to_bin(B) when is_binary(B) ->
    B;
to_bin(A) when is_atom(A) ->
    atom_to_binary(A, utf8);
to_bin(L) when is_list(L) ->
    unicode:characters_to_binary(L).
