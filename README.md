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
    $ rebar3 shell

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
  {cli, [{enabled, true}, {socket, "/var/tmp/mgmtd_ems.cli.socket"}]}
]}.
```

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


