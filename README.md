mgmtd_ems
=========

mgmtd_ems is an element-management node for RESTCONF supporting systems.

It is currently only tested against erlang nodes running mgmtd

Status
------

Experimental at this time, but has basic functionality

    mgmtd_ems (mgmtd + ecli)
         │
         └──RESTCONF──►  mgmtd (node) …
                         mgmtd (node) …
                         mgmtd (node) …

Build
-----

    $ rebar3 compile
    $ rebar3 eunit
    $ rebar3 shell          # loads config/sys.config (alice/secret, bob/guest)

Quick start
-----------

```erlang
1> application:ensure_all_started(mgmtd_ems).
2> mgmtd_ems:add_node(edge1, #{host => "192.0.2.10", port => 8008}).
ok
3> mgmtd_ems:nodes().
[#{name => edge1, host => "192.0.2.10", port => 8008, ...}]
4> mgmtd_ems:get(edge1, "data").
{ok, 200, _Hdrs, _Body}
```

Seed inventory from `sys.config` (imported into the local mgmtd store on first start):

```erlang
{mgmtd_ems, [
  {nodes, [
    {edge1, #{host => "192.0.2.10", port => 8008}},
    {edge2, #{host => "192.0.2.11", port => 8008,
              user => "alice", password => "secret"}}
  ]},
  {http, [
    {enabled, true},
    {port, 8081},
    {auth, [
      {users, [
        {"alice", "secret"},
        {"bob", "guest", read_only}
      ]}
    ]}
  ]},
  {cli, [{enabled, true}, {socket, "/var/tmp/mgmtd_ems.cli.socket"}]}
]}.
```

Web UI authentication is pluggable (`mgmtd_ems_auth`). The default module is a login form at `/login` against `{users, [...]}`. `{Name, Password}` is an `admin` (read and write); `{Name, Password, read_only}` can GET/HEAD/OPTIONS only, and the UI hides **Add node**, **Remove**, **Save**, **Delete**, **Add**, **Invoke**, and the **Actions** tab. A session cookie (`ems_sid`) is set on success; **Logout** clears it. Passwords are plaintext in config.

Omitted or empty `auth` still shows the login form, but nobody can sign in. Tests and local experiments must set `{auth, false}` to open the UI. A later OIDC (or other) module plugs in as `{auth, [{module, my_auth}, ...]}` — see `mgmtd_ems_auth`.

CLI (after `rebar3 shell` / `application:ensure_all_started(mgmtd_ems)`):

```
$ ./_build/default/lib/ecli/priv/ecli /var/tmp/mgmtd_ems.cli.socket

> configure
# set ems node edge1 host 192.0.2.10
# set ems node edge1 port 8008
# commit
# exit
> show configuration
> show status
> show status node edge1
```


