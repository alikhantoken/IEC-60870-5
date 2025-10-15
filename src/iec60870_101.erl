%%% +--------------------------------------------------------------+
%%% | Copyright (c) 2025. All Rights Reserved.                     |
%%% | License can be found in the LICENSE file.                    |
%%% | Author: Tokenov Alikhan, alikhantokenov@gmail.com            |
%%% +--------------------------------------------------------------+

-module(iec60870_101).

-include("iec60870.hrl").
-include("iec60870_ft12.hrl").
-include("iec60870_function_codes.hrl").

%%% +--------------------------------------------------------------+
%%% |                       Server & Client API                    |
%%% +--------------------------------------------------------------+

-export([
  start_server/1,
  stop_server/1,
  start_client/1
]).

%%% +--------------------------------------------------------------+
%%% |                        Shared functions                      |
%%% +--------------------------------------------------------------+

-export([
  connect/1,
  user_data_confirm/2,
  data_class/2
]).

%%% +--------------------------------------------------------------+
%%% |                       Macros & Records                       |
%%% +--------------------------------------------------------------+

-define(UPDATE_FCB(State, Request), State#state{fcb = Request#frame.control_field#control_field_request.fcb}).
-define(DEFAULT_MAX_MESSAGE_QUEUE, 1000).
-define(DEFAULT_IDLE_TIMEOUT, 30000).
-define(DEFAULT_CYCLE, 1000).
-define(REQUIRED, {?MODULE, required}).
-define(NOT(X), abs(X - 1)).

-define(UNBALANCED_CLIENT_SETTINGS, #{
  cycle => ?DEFAULT_CYCLE
}).

-define(DEFAULT_SETTINGS, #{
  balanced => ?REQUIRED,
  address => ?REQUIRED,
  address_size => ?REQUIRED,
  on_request => undefined,
  transport => #{
    name => undefined,
    baudrate => 9600,
    parity => 0,
    stopbits => 1,
    bytesize => 8
  }
}).

-record(state, {
  address,
  attempts,
  direction,
  fcb,
  portFT12,
  timeout,
  on_request
}).

%%% +--------------------------------------------------------------+
%%% |                    Server API implementation                 |
%%% +--------------------------------------------------------------+

start_server(Settings) ->
  Module =
    case Settings of
      #{balanced := false} ->
        iec60870_unbalanced_server;
      _Other ->
        iec60870_balanced_server
    end,
  OutSettings = check_settings(maps:merge(?DEFAULT_SETTINGS, Settings)),
  Root = self(),
  Server = Module:start(Root, OutSettings),
  {Module, Server}.

stop_server({Module, Server})->
  Module:stop(Server).

%%% +--------------------------------------------------------------+
%%% |                    Client API implementation                 |
%%% +--------------------------------------------------------------+

start_client(InSettings) ->
  {Module, Settings} =
    case InSettings of
      #{balanced := false} ->
        {iec60870_unbalanced_client, maps:merge(?UNBALANCED_CLIENT_SETTINGS, InSettings)};
      _Other ->
        {iec60870_balanced_client, InSettings}
    end,
  OutSettings = check_settings(maps:merge(?DEFAULT_SETTINGS, Settings)),
  Root = self(),
  Module:start(Root, OutSettings).

%%% +--------------------------------------------------------------+
%%% |               Shared functions implementation                |
%%% +--------------------------------------------------------------+

%% Connection transmission procedure initialization
connect(#{
  address := Address,
  attempts := Attempts,
  direction := Direction,
  portFT12 := PortFT12,
  timeout := Timeout,
  on_request := OnRequest
}) ->
  connect(#state{
    address = Address,
    attempts = Attempts,
    direction = Direction,
    fcb = undefined,
    portFT12 = PortFT12,
    timeout = Timeout,
    on_request = OnRequest
  });

%% Connection transmission procedure
%% Sequence:
%%   1. Request status of link
%%   2. Reset of remote link
%%   3. Request status of link
connect(#state{attempts = Attempts} = State) ->
  connect(Attempts, State).
connect(Attempts, #state{
  address = Address
} = State) when Attempts > 0 ->

  StateRequestLink1 = request_status_link(State),
  StateResetLink = reset_link(State),
  StateRequestLink2 = request_status_link(State),

  if
    StateRequestLink1 =:= error; StateResetLink =:= error; StateRequestLink2 =:= error ->
      ?LOGWARNING("failed to establish connection to link address: ~p, reset link: ~p, request link (1): ~p, request link (2): ~p", [
        Address,
        StateResetLink,
        StateRequestLink1,
        StateRequestLink2
      ]),
      ?LOGDEBUG("retrying to connect to link address: ~p, remaining attempts: ~p", [Address, Attempts - 1]),
      connect(Attempts - 1, State);
    true ->
      State#state{fcb = 0}
  end;
connect(_Attempts = 0, #state{
  address = Address
}) ->
  ?LOGERROR("failed to establish connection to link address: ~p, no attempts left...", [Address]),
  error.

data_class(DataClassCode, #state{attempts = Attempts} = State) ->
  data_class(Attempts, DataClassCode, State).

user_data_confirm(ASDU, #state{attempts = Attempts} = State) ->
  user_data_confirm(Attempts, ASDU, State).

%%% +--------------------------------------------------------------+
%%% |                  Reset link request sequence                 |
%%% +--------------------------------------------------------------+

reset_link(#state{
  portFT12 = PortFT12,
  address = Address
} = State) ->
  Request = build_request(?RESET_REMOTE_LINK, _Data = undefined, State),
  ?LOGDEBUG("sending [RESET LINK] to link address: ~p", [Address]),
  iec60870_ft12:send(PortFT12, Request),
  case wait_response(?ACKNOWLEDGE, undefined, State) of
    {ok, _} ->
      ?LOGDEBUG("acknowledged [RESET LINK] from link address: ~p", [Address]),
      ok;
    error ->
      ?LOGWARNING("no response to [RESET LINK] from link address: ~p, ft12: ~p", [Address, PortFT12]),
      error
  end.

%%% +--------------------------------------------------------------+
%%% |                 Request status link sequence                 |
%%% +--------------------------------------------------------------+

request_status_link(#state{
  portFT12 = PortFT12,
  address = Address
} = State) ->
  Request = build_request(?REQUEST_STATUS_LINK, _Data = undefined, State),
  ?LOGDEBUG("sending [REQUEST STATUS LINK] to link address: ~p", [Address]),
  iec60870_ft12:send(PortFT12, Request),
  case wait_response(?STATUS_LINK_ACCESS_DEMAND, undefined, State) of
    {ok, _} ->
      ?LOGDEBUG("acknowledged [REQUEST STATUS LINK] from link address: ~p", [Address]),
      ok;
    error ->
      ?LOGWARNING("no response to [REQUEST STATUS LINK] from link address: ~p, ft12: ~p", [Address, PortFT12]),
      error
  end.

%%% +--------------------------------------------------------------+
%%% |              User data confirm request sequence              |
%%% +--------------------------------------------------------------+

user_data_confirm(Attempts, ASDU, #state{
  portFT12 = PortFT12,
  address = Address
} = State) when Attempts > 0 ->
  Request = build_request(?USER_DATA_CONFIRM, ASDU, State),
  iec60870_ft12:send(PortFT12, Request),
  case wait_response(?ACKNOWLEDGE, undefined, State) of
    {ok, _} ->
      ?UPDATE_FCB(State, Request);
    error ->
      ?LOGWARNING("no response to [USER DATA CONFIRM] from link address: ~p, ft12: ~p", [Address, PortFT12]),
      user_data_confirm(Attempts - 1, ASDU, State)
  end;
user_data_confirm(_Attempts = 0, ASDU, #state{
  attempts = Attempts
} = State) ->
  retry(fun(NewState) -> user_data_confirm(Attempts, ASDU, NewState) end, State).

%%% +--------------------------------------------------------------+
%%% |                  Data class request sequence                 |
%%% +--------------------------------------------------------------+

data_class(Attempts, DataClassCode, #state{
  portFT12 = PortFT12,
  address = Address
} = State) when Attempts > 0 ->
  Request = build_request(DataClassCode, undefined, State),
  iec60870_ft12:send(PortFT12, Request),
  case wait_response(?USER_DATA, ?NACK_DATA_NOT_AVAILABLE, State) of
    {ok, #frame{control_field = #control_field_response{function_code = ?USER_DATA, acd = ACD}, data = ASDU}} ->
      NewState = ?UPDATE_FCB(State, Request),
      {NewState, ACD, ASDU};
    {ok, #frame{control_field = #control_field_response{function_code = ?NACK_DATA_NOT_AVAILABLE, acd = ACD}}} ->
      NewState = ?UPDATE_FCB(State, Request),
      {NewState, ACD, undefined};
    error ->
      ?LOGWARNING("no response to [DATA CLASS REQUEST] from link address: ~p, ft12: ~p", [Address, PortFT12]),
      data_class(Attempts - 1, DataClassCode, State)
  end;
data_class(_Attempts = 0, DataClassCode, #state{
  attempts = Attempts
} = State) ->
  retry(fun(NewState) -> data_class(Attempts, DataClassCode, NewState) end, State).

%%% +--------------------------------------------------------------+
%%% |                       Helper functions                       |
%%% +--------------------------------------------------------------+

wait_response(Response1, Response2, #state{
  portFT12 = PortFT12,
  address = Address,
  timeout = Timeout,
  on_request = OnRequest
} = State) ->
  receive
    {data, PortFT12, #frame{address = UnexpectedAddress}} when UnexpectedAddress =/= Address ->
      ?LOGWARNING("link address ~p received unexpected address: ~p", [Address, UnexpectedAddress]),
      wait_response(Response1, Response2, State);
    {single_char_ack, PortFT12} when Response1 =:= ?ACKNOWLEDGE ->
      {ok, single_char_ack};
    {single_char_ack, PortFT12} ->
      ?LOGDEBUG("link address ~p got unexpected single character ACK; ignoring", [Address]),
      wait_response(Response1, Response2, State);
    {data, PortFT12, #frame{
      control_field = #control_field_response{function_code = ResponseCode}
    } = Response} when ResponseCode =:= Response1; ResponseCode =:= Response2 ->
      {ok, Response};
    {data, PortFT12, #frame{control_field = #control_field_request{}} = Frame} when is_function(OnRequest) ->
      ?LOGDEBUG("link address ~p received request while waiting for response, request: ~p", [Address, Frame]),
      OnRequest(Frame),
      wait_response(Response1, Response2, State);
    {data, PortFT12, UnexpectedFrame} ->
      ?LOGWARNING("link address ~p received unexpected frame: ~p", [Address, UnexpectedFrame]),
      wait_response(Response1, Response2, State);
    {'EXIT', PortFT12, Reason} ->
      ?LOGERROR("link address ~p received EXIT from ft12: ~p, reason: ~p", [Address, PortFT12, Reason]),
      exit({transport_layer_failure, Reason})
  after
    Timeout ->
      ?LOGERROR("link address ~p timeout: ~p ms!", [Address, Timeout]),
      error
  end.

%% Retrying to connect and executing user-function
retry(Fun, State) ->
  case connect(State) of
    error -> error;
    NewState -> Fun(NewState)
  end.

%% Building a request frame (packet) to send
build_request(FunctionCode, UserData, #state{
  address = Address,
  direction = Direction,
  fcb = FCB
}) ->
  #frame{
    address = Address,
    control_field = #control_field_request{
      direction = Direction,
      fcb = handle_fcb(FunctionCode, FCB),
      fcv = handle_fcv(FunctionCode),
      function_code = FunctionCode
    },
    data = UserData
  }.

%% FCB - Frame count bit
%% Alternated between 0 to 1 for successive SEND / CONFIRM or
%% REQUEST / RESPOND transmission procedures
handle_fcb(FunctionCode, FCB) ->
  case FunctionCode of
    ?RESET_REMOTE_LINK   -> 0;
    ?REQUEST_STATUS_LINK -> 0;
    _ -> ?NOT(FCB)
  end.

%% FCV - Frame count bit valid
%% 1 - FCB is valid
%% 0 - FCB is invalid
handle_fcv(FunctionCode) ->
  case FunctionCode of
    ?REQUEST_DATA_CLASS_1 -> 1;
    ?REQUEST_DATA_CLASS_2 -> 1;
    ?USER_DATA_CONFIRM    -> 1;
    ?LINK_TEST            -> 1;
    _Other -> 0
  end.

check_settings(Settings) ->
  [begin
     case Value of
       ?REQUIRED ->
         throw({required, Key});
       _Exists ->
         check_setting(Setting)
     end
   end || {Key, Value} = Setting <- maps:to_list(Settings)],
  Settings.

check_setting({balanced, IsBalanced})
  when is_boolean(IsBalanced) -> ok;

check_setting({address, DataLinkAddress})
  when is_integer(DataLinkAddress) -> ok;

check_setting({address_size, DataLinkAddressSize})
  when is_integer(DataLinkAddressSize) -> ok;

check_setting({cycle, Cycle})
  when is_integer(Cycle) -> ok;

check_setting({attempts, Attempts})
  when is_integer(Attempts) -> ok;

check_setting({timeout, Timeout})
  when is_integer(Timeout) -> ok;

check_setting({on_request, OnRequest})
  when is_function(OnRequest) orelse OnRequest =:= undefined -> ok;

check_setting({transport, PortSettings})
  when is_map(PortSettings) -> ok;

check_setting(InvalidSetting) ->
  throw({invalid_setting, InvalidSetting}).

