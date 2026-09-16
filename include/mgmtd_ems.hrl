-ifndef(MGMTD_EMS_HRL).
-define(MGMTD_EMS_HRL, true).

%% Default RESTCONF listen port used by mgmtd.
-define(MGMTD_EMS_DEFAULT_PORT, 8008).

%% Default per-node probe interval (ms). `0` disables the timer (still
%% probes once on session start).
-define(MGMTD_EMS_DEFAULT_PROBE_INTERVAL, 30000).

%% Default northbound HTTP port for the erlydtl UI.
-define(MGMTD_EMS_DEFAULT_HTTP_PORT, 8080).

-endif.
