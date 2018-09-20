%
% The contents of this file are subject to the Mozilla Public License
% Version 1.1 (the "License"); you may not use this file except in
% compliance with the License. You may obtain a copy of the License at
% http://www.mozilla.org/MPL/
%
% Copyright (c) 2015 Petr Gotthard <petr.gotthard@centrum.cz>
%

% CoAP server application
% supervisor for content registry, listening socket and channel supervisor
-module(lwm2m_coap_server).

-behaviour(application).
-export([start/0, start/2, stop/1]).

-behaviour(supervisor).
-export([init/1]).
-export([start_udp/1, start_udp/2, start_udp/3, stop_udp/1, start_dtls/2, start_dtls/3, stop_dtls/1, channel_sup/1, start_registry/1]).

-include("coap.hrl").

start() ->
    start(normal, []).

start(normal, _Args) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

stop(_Pid) ->
    ok.

init([]) ->
    {ok, {{one_for_one, 3, 10}, [
        {lwm2m_coap_channel_sup_sup,
            {lwm2m_coap_channel_sup_sup, start_link, []},
            permanent, infinity, supervisor, []}
    ]}}.

start_udp(Name) ->
    start_udp(Name, ?DEFAULT_COAP_PORT).

start_udp(Name, UdpPort) ->
    start_udp(Name, UdpPort, []).

start_udp(Name, UdpPort, Options) ->
    supervisor:start_child(?MODULE,
        {Name,
            {lwm2m_coap_udp_socket, start_link, [UdpPort, whereis(?MODULE), Options]},
            permanent, 5000, worker, []}).

stop_udp(Name) ->
    supervisor:terminate_child(?MODULE, Name),
    supervisor:delete_child(?MODULE, Name).

start_dtls(Name, DtlsOpts) ->
    start_dtls(Name, ?DEFAULT_COAPS_PORT, DtlsOpts).

start_dtls(Name, DtlsPort, DtlsOpts) ->
    supervisor:start_child(?MODULE,
        {Name,
            {lwm2m_coap_dtls_listen_sup, start_link, [DtlsPort, DtlsOpts]},
            permanent, infinity, supervisor, [Name]}).

stop_dtls(Name) ->
    supervisor:terminate_child(?MODULE, Name),
    supervisor:delete_child(?MODULE, Name).

start_registry(ResourceHandlers) when is_list(ResourceHandlers) ->
    supervisor:start_child(?MODULE,
        {lwm2m_coap_server_registry,
            {lwm2m_coap_server_registry, start_link, [ResourceHandlers]},
            permanent, 5000, worker, []}).

channel_sup(SupPid) -> child(SupPid, lwm2m_coap_channel_sup_sup).

child(SupPid, Id) ->
    [Pid] = [Pid || {Id1, Pid, _, _} <- supervisor:which_children(SupPid),
        Id1 =:= Id],
    Pid.

% end of file
