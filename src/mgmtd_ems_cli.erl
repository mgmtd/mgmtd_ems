%%%-------------------------------------------------------------------
%% @doc Juniper-style CLI for the local EMS mgmtd instance.
%%
%% Minimum commands to configure fleet nodes stored under
%% `ems node <name> ...`.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_ems_cli).

-include_lib("ecli/include/ecli.hrl").

-export([init/0, init/1, banner/1, prompt/1, mode_after_exit/1, expand/2, execute/2]).
-export([open/0, close/0]).

-record(mgmtd_ems_cli,
        {mode = operational,
         user_txn,
         role = admin,
         user}).

%%--------------------------------------------------------------------
%% Socket
%%--------------------------------------------------------------------
open() ->
    case enabled() of
        false ->
            ok;
        true ->
            {ok, _} = application:ensure_all_started(ecli),
            Path = socket_path(),
            case ecli:open(Path, ?MODULE) of
                {ok, Pid} ->
                    application:set_env(mgmtd_ems, cli_pid, Pid),
                    ok;
                {error, _} = Err ->
                    Err
            end
    end.

close() ->
    case application:get_env(mgmtd_ems, cli_pid) of
        {ok, Pid} when is_pid(Pid) ->
            application:unset_env(mgmtd_ems, cli_pid),
            case is_process_alive(Pid) of
                true ->
                    _ = supervisor:terminate_child(ecli_sup, Pid),
                    ok;
                false ->
                    ok
            end;
        _ ->
            ok
    end.

enabled() ->
    proplists:get_value(enabled, cli_config(), true).

socket_path() ->
    proplists:get_value(socket, cli_config(),
                        "/var/tmp/mgmtd_ems.cli.socket").

cli_config() ->
    case application:get_env(mgmtd_ems, cli, []) of
        L when is_list(L) ->
            L;
        _ ->
            []
    end.

%%--------------------------------------------------------------------
%% CLI behaviour
%%--------------------------------------------------------------------
init() ->
    init(#{}).

init(Peer) when is_map(Peer) ->
    Role = mgmtd:aaa_role(Peer),
    User = maps:get(user, Peer, undefined),
    {ok, #mgmtd_ems_cli{role = Role, user = User}}.

banner(#mgmtd_ems_cli{role = Role, user = User}) ->
    Who =
        case User of
            undefined -> "";
            Name -> " as " ++ Name
        end,
    Hint =
        case Role of
            read_only -> " (read-only)";
            _ -> ""
        end,
    {ok,
     "\r\nWelcome to the mgmtd EMS CLI" ++ Who ++ Hint ++
         "\r\n\nHit TAB, SPC or "
         "? at any time to see available options\r\n\r\n"}.

prompt(#mgmtd_ems_cli{mode = Mode, user = User}) ->
    Suffix =
        case Mode of
            operational -> "> ";
            configuration -> "# "
        end,
    Host =
        case inet:gethostname() of
            {ok, Hostname} -> Hostname;
            _ -> ""
        end,
    Prefix =
        case User of
            undefined -> Host;
            Name when Host =:= "" -> Name;
            Name -> Name ++ "@" ++ Host
        end,
    {ok, Prefix ++ Suffix}.

mode_after_exit(#mgmtd_ems_cli{mode = operational}) ->
    stop;
mode_after_exit(#mgmtd_ems_cli{mode = configuration, user_txn = Txn} = J) ->
    mgmtd:txn_exit(Txn),
    J#mgmtd_ems_cli{mode = operational, user_txn = undefined}.

expand([], #mgmtd_ems_cli{mode = operational} = J) ->
    {no, [], ecli:format_menu(operational_menu(J)), J};
expand(Chars, #mgmtd_ems_cli{mode = operational} = J) ->
    expand_cmd(Chars, operational_menu(J), J);
expand([], #mgmtd_ems_cli{mode = configuration} = J) ->
    {no, [], ecli:format_menu(configuration_menu(J)), J};
expand(Chars, #mgmtd_ems_cli{mode = configuration} = J) ->
    expand_cmd(Chars, configuration_menu(J), J).

execute(CmdStr, #mgmtd_ems_cli{mode = operational} = J) ->
    case string:trim(CmdStr) of
        "exit" ->
            stop;
        _ ->
            execute_cmd(CmdStr, operational_menu(J), J)
    end;
execute(CmdStr, #mgmtd_ems_cli{mode = configuration} = J) ->
    execute_cmd(CmdStr, configuration_menu(J), J).

%%--------------------------------------------------------------------
%% Menus
%%--------------------------------------------------------------------
operational_menu(#mgmtd_ems_cli{role = Role}) ->
    ecli:permit(operational_cmds(), mgmtd:aaa_accesses(Role)).

operational_cmds() ->
    [#cmd{name = "show",
          desc = "Show commands",
          access = read,
          action = fun show_config/3,
          children = fun operational_show_menu/0,
          pipes = fun ecli_pipe:show_pipes/0},
     #cmd{name = "configure",
          desc = "Enter configuration mode",
          access = write,
          action = fun(J1, _) -> enter_config_mode(J1) end},
     #cmd{name = "exit",
          desc = "Close session",
          action = fun(J1) -> exit_session(J1) end}].

operational_show_menu() ->
    [#cmd{name = "configuration",
          desc = "Show current configuration",
          children = fun(Path) -> config_children(Path, show) end,
          action = fun show_config/3,
          pipes = fun ecli_pipe:config_show_pipes/0},
     #cmd{name = "status",
          desc = "Managed node operational status",
          access = read,
          children = fun oper_children/1,
          action = fun show_oper/2,
          pipes = fun ecli_pipe:show_pipes/0}].

configuration_menu(#mgmtd_ems_cli{role = Role}) ->
    ecli:permit(configuration_cmds(), mgmtd:aaa_accesses(Role)).

configuration_cmds() ->
    [#cmd{name = "show",
          desc = "Show configuration",
          access = read,
          children = fun(Path) -> config_children(Path, show) end,
          action = fun show_config/3,
          pipes = fun ecli_pipe:config_show_pipes/0},
     #cmd{name = "set",
          desc = "Set a configuration parameter",
          access = write,
          children = fun(Path) -> config_children(Path, set) end,
          action = fun set_config/2},
     #cmd{name = "delete",
          desc = "Delete a list item",
          access = write,
          children = fun(Path) -> config_children(Path, delete) end,
          action = fun delete_config/2},
     #cmd{name = "commit",
          desc = "Commit current changes",
          access = write,
          action = fun(J, _) -> commit_config(J) end},
     #cmd{name = "exit",
          desc = "Exit configuration mode",
          action = fun(J1, _) -> exit_config_mode(J1) end}].

%%--------------------------------------------------------------------
%% Actions
%%--------------------------------------------------------------------
exit_session(_J) ->
    stop.

enter_config_mode(#mgmtd_ems_cli{role = Role} = J) ->
    case mgmtd:aaa_permits(Role, write) of
        false ->
            {ok, "Permission denied\r\n", J};
        true ->
            Txn = mgmtd:txn_new(),
            {ok, "", J#mgmtd_ems_cli{mode = configuration, user_txn = Txn}}
    end.

set_config(#mgmtd_ems_cli{user_txn = Txn} = J, Path) ->
    case mgmtd:txn_set(Txn, Path) of
        {ok, Txn1} ->
            {ok, "updated\r\n", J#mgmtd_ems_cli{user_txn = Txn1}};
        {error, Reason} ->
            {ok, format_reason(Reason), J}
    end.

delete_config(#mgmtd_ems_cli{user_txn = Txn} = J, Path) ->
    case mgmtd:txn_delete(Txn, Path) of
        {ok, Txn1} ->
            {ok, "deleted\r\n", J#mgmtd_ems_cli{user_txn = Txn1}};
        {error, Reason} ->
            {ok, format_reason(Reason), J}
    end.

show_config(#mgmtd_ems_cli{user_txn = Txn} = J, Path0, Pipes) ->
    Path =
        if Path0 == undefined -> [];
           true -> Path0
        end,
    case ecli_pipe:compare_against(Pipes) of
        false ->
            Opts = case ecli_pipe:wants_defaults(Pipes) of
                       true -> #{defaults => true};
                       false -> #{}
                   end,
            {ok, ConfigTree} = mgmtd:txn_show(Txn, Path, Opts),
            {ok, {data, ConfigTree}, J};
        Against ->
            case mgmtd:txn_diff_text(Txn, Path, #{against => Against}) of
                {ok, Text} ->
                    {ok, Text, J};
                {error, Reason} ->
                    {ok, format_reason(Reason), J}
            end
    end.

commit_config(#mgmtd_ems_cli{user_txn = Txn} = J) ->
    case mgmtd:txn_commit(Txn) of
        {ok, Txn2} ->
            {ok, "ok\r\n", J#mgmtd_ems_cli{user_txn = Txn2}};
        {error, Reason} ->
            {ok, format_reason(Reason), J}
    end.

exit_config_mode(#mgmtd_ems_cli{user_txn = Txn} = J) ->
    mgmtd:txn_exit(Txn),
    {ok, "", J#mgmtd_ems_cli{mode = operational, user_txn = undefined}}.

show_oper(#mgmtd_ems_cli{} = J, Path0) ->
    Path = case Path0 of
               [] -> oper_root();
               undefined -> oper_root();
               _ -> oper_root() ++ Path0
           end,
    case mgmtd:txn_show(undefined, Path) of
        {ok, Tree} ->
            {ok, {data, Tree}, J};
        {error, Reason} ->
            {ok, format_reason(Reason), J}
    end.

%% First level under `show status` is the operational `status` container.
oper_children(_Path) ->
    mgmtd:schema_children(["status"], show).

oper_root() ->
    {ok, Path} = mgmtd_schema:lookup_path(["status"]),
    Path.

config_children(Path, CmdType) ->
    [C || C <- mgmtd:schema_children(Path, CmdType),
          maps:get(config, C, true)].

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------
format_reason(#{message := Msg}) ->
    format_reason(Msg);
format_reason(Reason) when is_binary(Reason) ->
    format_reason(binary_to_list(Reason));
format_reason(Reason) when is_list(Reason) ->
    case io_lib:printable_unicode_list(Reason) of
        true ->
            Reason ++ "\r\n";
        false ->
            lists:flatten(io_lib:format("~p\r\n", [Reason]))
    end;
format_reason(Reason) ->
    lists:flatten(io_lib:format("~p\r\n", [Reason])).

expand_cmd(Str, Menu, J) ->
    case ecli:expand(Str, Menu, J#mgmtd_ems_cli.user_txn) of
        no ->
            {no, [], [], J};
        {yes, Extra, MenuItems} ->
            {yes, Extra, MenuItems, J}
    end.

execute_cmd(CmdStr, Menu, #mgmtd_ems_cli{user_txn = Txn} = J) ->
    ecli:run(CmdStr, Menu, Txn, J).
