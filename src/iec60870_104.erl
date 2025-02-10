%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-module(iec60870_104).

-include("iec60870.hrl").
-include("asdu.hrl").

%%% +--------------------------------------------------------------+
%%% |                      Server & Client API                     |
%%% +--------------------------------------------------------------+

-export([
  start_server/1,
  stop_server/1,
  start_client/1
]).

%%% +--------------------------------------------------------------+
%%% |                       Macros & Records                       |
%%% +--------------------------------------------------------------+

-define(DEFAULT_SOCKET_PARAMS, [binary, {active, true}, {packet, raw}]).

%% Default port settings
-define(DEFAULT_SETTINGS, #{
  connect_attempts => 3,
  address => local,
  port => ?DEFAULT_PORT,
  t1 => 30000,
  t2 => 5000,
  t3 => 15000,
  k => 12,
  w => 8
}).

%% Default port
-define(DEFAULT_PORT, 2404).

-define(MAX_PORT_VALUE, 65535).
-define(MIN_PORT_VALUE, 0).

%% Max K and W value
-define(MAX_COUNTER, 32767).
-define(REQUIRED, {?MODULE, required}).

% Each packet (APDU) starts with
-define(START_BYTE, 16#68).

% Packet (APDU) types
-define(U_TYPE, 2#11).
-define(S_TYPE, 2#01).
-define(I_TYPE, 2#00).

% Unnumbered control functions
-define(START_DT_ACTIVATE,   2#000001).
-define(START_DT_CONFIRM,    2#000010).
-define(STOP_DT_ACTIVATE,    2#000100).
-define(STOP_DT_CONFIRM,     2#001000).
-define(TEST_FRAME_ACTIVATE, 2#010000).
-define(TEST_FRAME_CONFIRM,  2#100000).

-define(CONNECT_TIMEOUT, 5000).
-define(WAIT_ACTIVATE, 5000).
-define(RESTART_WAIT, 1000).

-record(state, {
  socket,
  connection,
  settings,
  buffer,
  t1,
  t2,
  t3,
  vs = 0,
  vr = 0,
  overflows = 0,
  vw,
  sent = []
}).

%%% +--------------------------------------------------------------+
%%% |                    Server API implementation                 |
%%% +--------------------------------------------------------------+

start_server(InSettings) ->
  Root = self(),
  Settings = #{
    port := Port,
    address := Address
  } = check_settings(maps:merge(?DEFAULT_SETTINGS, InSettings)),
  SocketParams = get_socket_params(Address),
  case gen_tcp:listen(Port, SocketParams) of
    {ok, ListenSocket} ->
      accept_connection(ListenSocket, Settings, Root),
      ListenSocket;
    {error, eaddrinuse} ->
      timer:sleep(?RESTART_WAIT),
      ?LOGWARNING("~p port is in use, trying to reuse", [Port]),
      ?LOGWARNING("ENSURE OTHER APPLICATIONS DO NOT USE PORT ~p, THIS MAY LEAD TO CONFLICTS", [Port]),
      ?LOGWARNING("trying to open port ~p in shared mode", [Port]),
      case gen_tcp:listen(Port, [{reuseaddr, true} | SocketParams]) of
        {ok, ListenSocket} ->
          ?LOGWARNING("port ~p opened in shared mode", [Port]),
          accept_connection(ListenSocket, Settings, Root),
          ListenSocket;
        {error, Reason} ->
          throw({transport_error, Reason})
      end;
    {error, Reason} ->
      throw({transport_error, Reason})
  end.

stop_server(ServerPort) ->
  gen_tcp:close(ServerPort).

%%% +--------------------------------------------------------------+
%%% |                    Client API implementation                 |
%%% +--------------------------------------------------------------+

start_client(InSettings) ->
  Owner = self(),
  Settings = check_settings(maps:merge(?DEFAULT_SETTINGS#{
    host => ?REQUIRED
  }, InSettings)),
  Attempts = maps:get(connect_attempts, Settings ),
  PID = spawn_link(fun() -> init_client(Attempts, Owner, Settings) end),
  receive
    {ready, PID} -> PID;
    {'EXIT', PID, Reason} -> throw(Reason)
  end.

%%% +--------------------------------------------------------------+
%%% |                    Internal helper functions                 |
%%% +--------------------------------------------------------------+

%% Waiting for incoming connections (clients)
accept_connection(ListenSocket, #{port := Port} = Settings, Root) ->
  spawn(fun() ->
    Socket = accept_loop(ListenSocket, Root),
    % Handle the ListenSocket to the next process
    accept_connection(ListenSocket, Settings, Root),
    ?LOGDEBUG("server on port ~p: accepted an incoming connection, waiting for START ACTIVATE", [Port]),
    case wait_activate(Socket, ?START_DT_ACTIVATE, <<>>) of
      {ok, Buffer} ->
        ?LOGDEBUG("server on port ~p: START ACTIVATE received, reply with START CONFIRM", [Port]),
        socket_send(Socket, create_u_packet(?START_DT_CONFIRM)),
        case iec60870_server:start_connection(Root, ListenSocket, self()) of
          {ok, Connection} ->
            init_loop(#state{
              socket = Socket,
              connection = Connection,
              settings = Settings,
              buffer = Buffer
            });
          error ->
            ?LOGERROR("unable to start a process to handle the incoming connection with internal error"),
            gen_tcp:close(Socket),
            exit(start_connection_error)
        end;
      {error, ActivateError} ->
        ?LOGWARNING("error activating incoming connection: ~p", [ActivateError]),
        gen_tcp:close(Socket),
        exit(ActivateError)
    end
  end).

accept_loop(ListenSocket, Root) ->
  case gen_tcp:accept(ListenSocket) of
    {ok, Socket} ->
      Socket;
    {error, Error} ->
      catch gen_tcp:close(ListenSocket),
      exit(Root, Error),
      exit(Error)
  end.

init_loop(#state{
  settings = #{w := W}
} = State0) ->
  State = start_t3(State0),
  loop(State#state{
    vs = 0,
    vr = 0,
    vw = W,
    sent = []
  }).

loop(#state{
  settings = #{k := K},
  buffer = Buffer,
  socket = Socket,
  sent = Sent
} = State) ->
  receive
    % Data is received from the transport level (TCP)
    {tcp, Socket, Data}->
      {Packets, TailBuffer} = split_into_packets(<<Buffer/binary, Data/binary>>),
      State1 = handle_packets(Packets, State),
      State2 = start_t3(State1),
      loop(State2#state{buffer = TailBuffer});

    % A packet is received from the connection
    % It is crucial to note that we need to compare the sent packets
    % with K since we are awaiting confirmation (S-packet)
    % Sending additional packets may lead to a disruption in the connection
    % as it could surpass the maximum threshold (K) of unconfirmed packets
    {asdu, From, Reference, ASDU} when length(Sent) =< K ->
      From ! {confirm, Reference},
      State1 = send_i_packet(ASDU, State),
      State2 = start_t1(State1),
      loop(State2);

    % Commands that were sent to self and others are ignored and unexpected
    {Self, Command} when Self =:= self() ->
      State1 = handle_command(Command, State),
      loop(State1);

    % Errors from TCP
    {tcp_closed, Socket} ->
      exit(closed);
    {tcp_error, Socket, Reason} ->
      exit(Reason);
    {tcp_passive, Socket} ->
      exit(tcp_passive);

    % If an ASDU packet isn't accepted because we are waiting for confirmation,
    % we should compare the sent packets with K to avoid ignoring other ASDUs
    Unexpected when length(Sent) =< K ->
      ?LOGWARNING("unexpected message received ~p", [Unexpected]),
      loop(State)
  end.

%% Client connection sequence
init_client(Attempts, Owner, #{
  host := Host,
  port := Port
} = Settings) when Attempts > 0->
  case gen_tcp:connect(Host, Port, [binary, {active, true}, {packet, raw}], ?CONNECT_TIMEOUT) of
    {ok, Socket} ->
      % Sending the activation command and waiting for its confirmation
      socket_send(Socket, create_u_packet(?START_DT_ACTIVATE)),
      ?LOGDEBUG("client ~p: sending START ACTIVATE", [Host]),
      case wait_activate(Socket, ?START_DT_CONFIRM, <<>>) of
        {ok, Buffer} ->
          ?LOGDEBUG("client ~p: START CONFIRM", [Host]),
          % The confirmation has been received and the client is ready to work
          Owner ! {ready, self()},
          init_loop(#state{
            socket = Socket,
            connection = Owner,
            settings = Settings,
            buffer = Buffer
          });
        {error, ActivateError} ->
          ?LOGWARNING("client connection activation error: ~p", [ActivateError]),
          gen_tcp:close(Socket),
          init_client( Attempts - 1, Owner, Settings )
      end;
    {error, ConnectError} ->
      ?LOGWARNING("client open socket error: ~p", [ConnectError]),
      init_client( Attempts - 1, Owner, Settings )
  end;
init_client(_Attempts, _Owner, _Settings)->
  exit( connect_error ).

%% Connection activation wait
wait_activate(Socket, Code, Buffer) ->
  receive
    {tcp, Socket, Data} ->
      case <<Buffer/binary, Data/binary>> of
        <<?START_BYTE, 4:8, Code:6, ?U_TYPE:2, _:3/binary, RestBuffer/binary>> ->
          {ok, RestBuffer};
        Head = <<?START_BYTE, _/binary>> when size(Head) < 6 ->
          wait_activate(Socket, Code, Head);
        Unexpected ->
          {error, {unexpected_request, Unexpected}}
      end;
    {tcp_closed, Socket} ->
      {error, closed};
    {tcp_error, Socket, Reason} ->
      {error, Reason};
    {tcp_passive, Socket} ->
      {error, tcp_passive}
  after
    ?WAIT_ACTIVATE -> {error, timeout}
  end.

%% T1 - APDU timeout
handle_command(t1, _State) ->
  exit(confirm_timeout);

%% T2 - Acknowledge timeout
handle_command(t2, State) ->
  confirm_received_counter( State );

%% T3 - Heartbeat timeout (Test frames)
handle_command(t3, #state{
  t3 = {init, _Timer},
  socket = Socket,
  settings = #{t1 := T1}
} = State) ->
  socket_send(Socket, create_u_packet(?TEST_FRAME_ACTIVATE)),
  % We start the t3 timer with T1 duration because according to
  % IEC 60870-5-104 the confirmation of test frame should be sent back
  % within T1
  Timer = init_timer( t3, T1 ),
  State#state{t3 = {confirm, Timer}};

handle_command(t3, #state{
  t3 = {confirm, _Timer}
}) ->
  exit(heartbeat_timeout);

handle_command(InvalidCommand, _State) ->
  throw({invalid_command, InvalidCommand}).

%% Attaching the beginning of the packet and its size to the frame
create_apdu(Frame) ->
  Size = byte_size(Frame),
  <<?START_BYTE, Size:8, Frame/binary>>.

split_into_packets(Data) ->
  split_into_packets(Data, []).

split_into_packets(<<?START_BYTE, Size:8, Rest/binary>> = Data, Packets) ->
  case Rest of
    <<Packet:Size/binary, Tail/binary>>->
      split_into_packets(Tail, [Packet | Packets]);
    _ ->
      {lists:reverse(Packets), Data}
  end;
split_into_packets(<<?START_BYTE, _Size:8>>, Packets) ->
  {lists:reverse(Packets), <<>>};
split_into_packets(<<?START_BYTE>>, Packets) ->
  {lists:reverse(Packets), <<>>};
split_into_packets(<<>>, Packets) ->
  {lists:reverse(Packets), <<>>};
split_into_packets(InvalidData, _) ->
  throw({invalid_input_data_format, InvalidData}).

handle_packets([Packet | Rest], State)->
  {Type, Data} = parse_packet(Packet),
  State1 = handle_packet(Type, Data, State),
  handle_packets(Rest, State1);
handle_packets([], State)->
  State.

%%% +--------------------------------------------------------------+
%%% |                       Packet parsing                         |
%%% +--------------------------------------------------------------+
%%% | APCI - Application protocol control information              |
%%% | I-type: Information transfer format                          |
%%% |           Contains ASDU                                      |
%%% | S-type: Numbered supervisory functions                       |
%%% |           Contains APCI only                                 |
%%% | U-type: Unnumbered control functions                         |
%%% |           Contains TESTFR or STOPDT or STARTDT               |
%%% +--------------------------------------------------------------+

%% U-type APCI
parse_packet(<<
  Load:6, ?U_TYPE:2,  % Control Field 1
  _Ignore:3/binary    % Control Field 2..Control Field 4
>>) ->
  {u, Load};

%% S-type APCI
parse_packet(<<
  _:6, ?S_TYPE:2,     % Control Field 1
  _:1/binary,         % Control Field 2
  LSB:7, 0:1,         % Control Field 3
  MSB:8               % Control Field 4
>>) ->
  <<Counter:15>> = <<MSB:8, LSB:7>>,
  {s, Counter};

%% I-type APCI
parse_packet(<<
  LSB_S:7, ?I_TYPE:1, % Control Field 1
  MSB_S:8,            % Control Field 2
  LSB_R:7, 0:1,       % Control Field 3
  MSB_R:8,            % Control Field 4
  ASDU/binary
>>)->
  <<Counter_S:15>> = <<MSB_S:8, LSB_S:7>>,
  <<Counter_R:15>> = <<MSB_R:8, LSB_R:7>>,
  {i, {Counter_S, Counter_R, ASDU}};

parse_packet(InvalidFrame)->
  throw({invalid_frame, InvalidFrame}).

%%% +--------------------------------------------------------------+
%%% |                         Packet build                         |
%%% +--------------------------------------------------------------+

create_u_packet(Code) ->
  create_apdu(<<Code:6, 1:1, 1:1, 0:24>>).

create_s_packet(VR) ->
  <<MSB:8, LSB:7>> = <<VR:15>>,
  create_apdu(<<
    0:6, 0:1, 1:1,
    0:8,
    LSB:7, 0:1,
    MSB:8
  >>).

create_i_packet(ASDU, #state{
  vr = VR,
  vs = VS
}) ->
  <<MSB_R:8, LSB_R:7>> = <<VR:15>>,
  <<MSB_S:8, LSB_S:7>> = <<VS:15>>,
  create_apdu(<<
    LSB_S:7, 0:1,
    MSB_S:8,
    LSB_R:7, 0:1,
    MSB_R:8,
    ASDU/binary
  >>).

%%% +--------------------------------------------------------------+
%%% |                     U-type packet handle                     |
%%% +--------------------------------------------------------------+

handle_packet(u, ?START_DT_CONFIRM, State)->
  ?LOGWARNING("unexpected START_DT_CONFIRM packet was received!"),
  State;

handle_packet(u, ?TEST_FRAME_ACTIVATE, #state{
  socket = Socket
} = State) ->
  socket_send(Socket, create_u_packet(?TEST_FRAME_CONFIRM)),
  State;

handle_packet(u, ?TEST_FRAME_CONFIRM, #state{
  t3 = {confirm, Timer}
} = State) ->
  reset_timer(t3, Timer),
  State#state{t3 = undefined};

handle_packet(u, _Data, State)->
  % TODO: Is it correct to ignore other types of U packets?
  State;

%%% +--------------------------------------------------------------+
%%% |                     S-type packet handle                     |
%%% +--------------------------------------------------------------+

handle_packet(s, ReceiveCounter, State) ->
  confirm_sent_counter( ReceiveCounter, State );

%%% +--------------------------------------------------------------+
%%% |                     I-type packet handle                     |
%%% +--------------------------------------------------------------+

handle_packet(i, Packet, #state{
  vw = 1
} = State) ->
  State1 = handle_packet(i, Packet, State#state{vw = 0}),
  % Sending an acknowledge because the number of
  % unacknowledged i-packets is reached its limit.
  confirm_received_counter( State1 );

handle_packet(i, {SendCounter, ReceiveCounter, ASDU}, #state{
  vr = VR,
  vw = VW,
  connection = Connection
} = State) when SendCounter =:= VR ->

  Connection ! {asdu, self(), ASDU},

  NewState = start_t2(State),
  % When control field of received packets
  % is overflowed we should reset its value.
  NewVR =
    case VR >= ?MAX_COUNTER of
      true  -> 0;
      false -> VR + 1
    end,

  confirm_sent_counter( ReceiveCounter, NewState#state{
    vr = NewVR,
    vw = VW - 1
  });

%% When the quantity of transmitted packets does not match
%% the number of packets received by the client.
handle_packet(i, {SendCounter, _ReceiveCounter, _ASDU}, #state{vr = VR}) ->
  exit({invalid_receive_counter, SendCounter, VR}).

send_i_packet(ASDU, #state{
  settings = #{
    w := W,
    k := K
  },
  vs = VS,
  socket = Socket,
  sent = Sent
} = State) ->
  if
    length(Sent) =< K ->
      APDU = create_i_packet(ASDU, State),
      socket_send(Socket, APDU);
    true ->
      exit({max_number_of_unconfirmed_packets_reached, K})
  end,
  %% When control field of sent packets
  %% is overflowed we should reset its value.
  NewVS = VS + 1,
  UpdatedOverflowCount = NewVS div ?MAX_COUNTER,
  State#state{
    vs = NewVS,
    vw = W,
    overflows = UpdatedOverflowCount,
    sent = [NewVS | Sent]
  }.

%% +--------------------------------------------------------------+
%% |                      Validate settings                       |
%% +--------------------------------------------------------------+

check_settings(Settings) ->
  SettingsList = maps:to_list(maps:merge(?DEFAULT_SETTINGS, Settings)),
  case [S || {S, ?REQUIRED} <- SettingsList] of
    [] -> ok;
    Required -> throw({required_setting, Required})
  end,
  case maps:keys(Settings) -- [host | maps:keys(?DEFAULT_SETTINGS)] of
    [] -> ok;
    InvalidParams -> throw({invalid_settings, InvalidParams})
  end,
  maps:from_list([{K, check_setting(K, V)} || {K, V} <- SettingsList]).

check_setting(address, local = Address) ->
  Address;
check_setting(address, Address)
  when is_list(Address) -> Address;

check_setting(host, Host) when is_tuple(Host) ->
  case tuple_to_list(Host) of
    IP when length(IP) =:= 4 ->
      case [Octet || Octet <- IP, is_integer(Octet), Octet >= 0, Octet =< 255] of
        IP -> Host;
        _  -> throw({invalid_setting, Host})
      end;
    _ -> throw({invalid_setting, Host})
  end;

check_setting(port, Port)
  when is_number(Port), Port >= ?MIN_PORT_VALUE, Port =< ?MAX_PORT_VALUE -> Port;

check_setting(k, Value)
  when is_number(Value), Value >= ?MIN_FRAME_LIMIT, Value =< ?MAX_FRAME_LIMIT -> Value;

check_setting(w, Value)
  when is_number(Value), Value >= ?MIN_FRAME_LIMIT, Value =< ?MAX_FRAME_LIMIT -> Value;

check_setting(t1, Timeout)
  when is_number(Timeout) -> Timeout;

check_setting(t2, Timeout)
  when is_number(Timeout) -> Timeout;

check_setting(t3, Timeout)
  when is_number(Timeout); Timeout =:= infinity -> Timeout;

check_setting(connect_attempts, Attempts)
  when is_integer(Attempts) -> Attempts;

check_setting(Key, Value)->
  throw({invalid_setting, {setting, Key, value, Value}}).

%% +--------------------------------------------------------------+
%% |                       Helper functions                       |
%% +--------------------------------------------------------------+

get_socket_params(Address) when is_list(Address) ->
  {ok, ParsedAddress} = inet:parse_address(Address),
  ?DEFAULT_SOCKET_PARAMS ++ [{ip, ParsedAddress}];
get_socket_params(_Other) ->
  ?DEFAULT_SOCKET_PARAMS.

confirm_sent_counter(ReceiveCounter, #state{
  sent = Sent,
  t1 = PrevTimer,
  overflows = OverflowCount,
  settings = #{t1 := T1}
} = State) ->
  reset_timer(t1, PrevTimer),
  Unconfirmed = [S || S <- Sent, (ReceiveCounter + (OverflowCount * ?MAX_COUNTER)) < S],

  % ATTENTION. According to the IEC 60870-5-104 we have to start timer from the point
  % of the first unconfirmed packet, but for the simplicity of implementation we start if
  % from the point of the last confirmation. This means that the actual time of waiting for
  % the confirmation may be longer than the T1 setting
  Timer =
    if
      length(Unconfirmed) > 0 -> init_timer(t1, T1);
      true -> undefined
    end,

  State#state{
    t1 = Timer,
    sent = Unconfirmed
  }.

confirm_received_counter(#state{
  t2 = Timer,
  socket = Socket,
  vr = VR,
  settings = #{
    w := W
  }
} = State) ->
  UpdatedVR = create_s_packet(VR),
  socket_send(Socket, UpdatedVR),
  reset_timer(t2, Timer),
  State#state{
    vw = W,
    t2 = undefined
  }.

start_t1(#state{
  t1 = Timer
} = State) when is_reference(Timer) ->
  State;
start_t1(#state{
  settings = #{t1 := T1}
} = State) ->
  State#state{
    t1 = init_timer(t1, T1)
  }.

start_t2(#state{
  t2 = Timer
} = State) when is_reference(Timer) ->
  State;
start_t2(#state{
  settings = #{t2 := T2}
} = State) ->
  State#state{
    t2 = init_timer(t2, T2)
  }.

start_t3(#state{
  t3 = {confirm, _}
} = State) ->
  State;

start_t3(#state{
  t3 = {_, PrevTimer},
  settings = #{t3 := T3}
} = State) ->
  Timer = restart_timer(t3, T3, PrevTimer),
  State#state{
    t3 = {init, Timer}
  };

start_t3(#state{
  settings = #{t3 := T3}
} = State) ->
  Timer = init_timer(t3, T3),
  State#state{
    t3 = {init, Timer}
  }.

init_timer(Type, Duration) ->
  Self = self(),
  erlang:send_after(Duration, Self, {Self, Type}).

restart_timer(Type, Duration, Timer) ->
  reset_timer(Type, Timer),
  init_timer(Type, Duration).

reset_timer(Type, Timer) when is_reference(Timer) ->
  erlang:cancel_timer(Timer),
  clear_timer(Type);
reset_timer(_Type, _Timer) ->
  ok.

%% Clearing the mailbox from timer messages
clear_timer(Type) ->
  receive
    {Self, Type} when Self =:= self() -> clear_timer( Type )
  after
    0 -> ok
  end.

socket_send(Socket, Data) ->
  case gen_tcp:send(Socket, Data) of
    ok -> ok;
    {error, Error} -> exit({send_error, Error})
  end.