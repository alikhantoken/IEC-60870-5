%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License that can be found in the LICENSE file.                 |
%%% +----------------------------------------------------------------+

-module(iec60870_switch).

-include("iec60870.hrl").
-include("iec60870_ft12.hrl").

%%% +--------------------------------------------------------------+
%%% |                             API                              |
%%% +--------------------------------------------------------------+

-export([
  start/1,
  add_server/2
]).

%%% +--------------------------------------------------------------+
%%% |                       Macros & Records                       |
%%% +--------------------------------------------------------------+

-record(state, {
  name,
  port_ft12,
  servers,
  options
}).

-define(SILENT_TIMEOUT, 60000).

%%% +--------------------------------------------------------------+
%%% |                      API implementation                      |
%%% +--------------------------------------------------------------+

start(Options) ->
  Owner = self(),
  PID = spawn_link(fun() -> init_switch(Owner, Options) end),
  receive
    {ready, PID, PID} ->
      PID;
    {ready, PID, Switch} ->
      link(Switch),
      Switch
  end.

add_server(Switch, Address) ->
  Switch ! {add_server, self(), Address},
  receive {ok, Switch} -> ok end.

%%% +--------------------------------------------------------------+
%%% |                      Internal functions                      |
%%% +--------------------------------------------------------------+

init_switch(ServerPID, #{transport := #{name := PortName}} = Options) ->
  RegisteredName = list_to_atom(PortName),
  case catch register(RegisteredName, self()) of
    % Probably already registered
    % Check the registered PID by the port name
    {'EXIT', _} ->
      case whereis(RegisteredName) of
        Switch when is_pid(Switch) ->
          ServerPID ! {ready, self(), Switch};
        _ ->
          init_switch(ServerPID, Options)
      end;
    % Succeeded to register port, start the switch
    true ->
      OptionsFT12 = maps:with([transport, address_size], Options),
      case catch iec60870_ft12:start_link( OptionsFT12 ) of
        {'EXIT', Error} ->
          ?LOGERROR("~p failed to start transport layer (ft12), error: ~p", [PortName, Error]),
          exit({transport_layer_init_failure, Error});
        PortFT12 ->
          process_flag(trap_exit, true),
          ServerPID ! {ready, self(), self()},
          switch_loop(#state{
            port_ft12 = PortFT12,
            name = PortName,
            options = OptionsFT12,
            servers = #{}
          })
      end
  end.

switch_loop(#state{
  name = Name,
  port_ft12 = PortFT12,
  servers = Servers
} = State) ->
  receive
    % Message from FT12
    {data, PortFT12, Frame = #frame{address = LinkAddress}} ->
      % Check if the link address is served by a switch
      case maps:get(LinkAddress, Servers, none) of
        none ->
          ?LOGWARNING("~p received unexpected link address: ~p", [Name, LinkAddress]);
        ServerPID ->
          ServerPID ! {data, self(), Frame}
      end,
      switch_loop(State);

      % Forward SCA requests from server to FT1.2
    {send_sca, ServerPID} ->
      case lists:member(ServerPID, maps:values(Servers)) of
        true  -> iec60870_ft12:send_sca(PortFT12);
        false -> ?LOGWARNING("~p received send_sca from unknown server ~p", [Name, ServerPID])
      end,
      switch_loop(State);

    {single_char_ack, PortFT12} ->
      ?LOGDEBUG("~p received single character ACK from line; ignoring", [Name]),
      switch_loop(State);

    % Handle send requests from the server
    {send, ServerPID, Frame = #frame{address = LinkAddress}} ->
      % Checking if the link address is served by a switch
      case maps:get(LinkAddress, Servers, none) of
        none ->
          ?LOGWARNING("~p received unexpected link address for data transmit: ~p", [Name, LinkAddress]);
        ServerPID ->
          iec60870_ft12:send(PortFT12, Frame);
        _Other ->
          ?LOGWARNING("~p received unexpected server PID: ~p", [ServerPID])
      end,
      switch_loop(State);

    % Add new server to the switch
    {add_server, ServerPID, LinkAddress } ->
      ServerPID ! {ok, self()},
      switch_loop(State#state{
        % Link addresses are associated with server PIDs
        servers = Servers#{LinkAddress => ServerPID}
      });

    % Port FT12 is down, transport level is unavailable
    {'EXIT', PortFT12, Reason} ->
      ?LOGERROR("~p received EXIT from transport layer (ft12), reason: ~p", [Name, Reason]),
      exit(Reason);

    % Message from the server which has been shut down
    {'EXIT', DeadServer, _Reason} ->
      % Retrieve all servers except the one that has been shut down
      RestServers = maps:filter(fun(_A, PID) -> PID =/= DeadServer end, Servers),
      if
        map_size(RestServers) =:= 0 ->
          ?LOGINFO("~p terminating, no servers left...", [Name]),
          iec60870_ft12:stop(PortFT12),
          exit(shutdown);
        true ->
          switch_loop(State#state{servers = RestServers})
      end;
    Unexpected ->
      ?LOGWARNING("~p received unexpected message: ~p", [Name, Unexpected]),
      switch_loop(State)
  after
    ?SILENT_TIMEOUT ->
      ?LOGWARNING("~p entered silence timeout, reinitializing transport layer...", [Name]),
      NewState = restart_transport(State),
      ?LOGINFO("~p successfully reinitialized after silence timeout!", [Name]),
      switch_loop(NewState)
  end.

restart_transport(#state{
  name = Name,
  port_ft12 = PortFT12,
  options = Options
} = State) ->
  ?LOGDEBUG("~p stopping transport layer (ft12): ~p", [Name, PortFT12]),
  iec60870_ft12:stop(PortFT12),
  wait_stopped(PortFT12),
  ?LOGDEBUG("~p transport layer stopped successfully (ft12): ~p", [Name, PortFT12]),
  case catch iec60870_ft12:start_link(Options) of
    {'EXIT', Error} ->
      ?LOGERROR("~p failed to restart transport layer, error: ~p", [Name, Error]),
      exit({transport_layer_reinit_failure, Error});
    NewPortFT12 ->
      State#state{port_ft12 = NewPortFT12}
  end.

wait_stopped(PortFT12) ->
  case is_process_alive(PortFT12) of
    true ->
      timer:sleep(10),
      wait_stopped(PortFT12);
    _ ->
      ok
  end.

