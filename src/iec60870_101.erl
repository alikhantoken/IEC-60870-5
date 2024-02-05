-module(iec60870_101).

-include("iec60870.hrl").
-include("ft12.hrl").

-export([
  start_server/1,
  stop_server/1,
  start_client/1
]).

-export([
  connect/4,
  transaction/4,
  send_receive/3
]).

%--------request codes-------------------
-define(RESET_REMOTE_LINK, 0).
-define(LINK_TEST, 2).
-define(USER_DATA_CONFIRM, 3).
-define(REQUEST_STATUS_LINK, 9).

-define(REQUEST_DATA_CLASS_1, 10).
-define(REQUEST_DATA_CLASS_2, 11).

-define(ACKNOWLEDGE, 0).
-define(STATUS_LINK_ACCESS_DEMAND, 11).


-define(NOT(X), abs(X - 1)).

-define(REQUIRED, {?MODULE, required}).

-define(DEFAULT_SETTINGS, #{
  port => ?REQUIRED,
  balanced => ?REQUIRED,
  address => ?REQUIRED,
  port_options => #{
    baudrate => 9600,
    parity => 0,
    stopbits => 1,
    bytesize => 8
  },
  address_size => 1
}).

-record(state,{
  address,
  direction,
  send_receive,
  fcb,
  attempts
}).

start_server(InSettings) ->
  Root = self(),
  Settings = check_settings(maps:merge(?DEFAULT_SETTINGS, InSettings)),
  Module =
    case Settings of
      #{balanced := false} -> iec60870_unbalanced_server;
      _ -> iec60870_balanced_server
    end,
  Server = Module:start(Root, Settings),
  {Module, Server}.

stop_server({Module, Server})->
  Module:stop(Server).

start_client(InSettings) ->
  Settings = check_settings(maps:merge(?DEFAULT_SETTINGS, InSettings)),
  Owner = self(),
  Module =
    case Settings of
      #{balanced := false} -> iec60870_unbalanced_client;
      _ -> iec60870_balanced_client
    end,
  Module:start(Owner, Settings).

check_settings(Settings) ->
  % TODO: Add settings validation
  Settings.


%%====================================================================================
%%  101 request-response transaction
%%====================================================================================
connect( Address, Direction, SendReceive, Attempts )->
  connect(#state{
    address = Address,
    direction = Direction,
    send_receive = SendReceive,
    fcb = undefined,
    attempts = Attempts
  }).


connect(InState) ->

  case reset_link( InState ) of
    {ok, ResetState} ->
      OnResponse =
        fun( Response )->
          case Response of
            #frame{ control_field = #control_field_response{
              function_code = ?STATUS_LINK_ACCESS_DEMAND
            }} ->
              ok;
            _->
              error
          end
        end,

      transaction(?REQUEST_STATUS_LINK, _Data = undefined, OnResponse, ResetState);
    Error->
      Error
  end.

transaction(FC, Data, OnResponse, #state{ attempts = Attempts }=State)->
  transaction(Attempts, FC, Data, OnResponse, State).
transaction(Attempts, FC, Data, OnResponse, #state{
  send_receive = SendReceive
}=State)->

  Request = request(FC, Data, State),
  case SendReceive( Request ) of
    {ok, Response} ->
      case OnResponse( Response ) of
        ok ->
          NewFCB = Request#frame.control_field#control_field_request.fcb,
          {ok, State#state{ fcb = NewFCB }};
        error ->
          ?LOGWARNING("unexpected response received, request: ~p, response ~p",[ Request, Response ]),
          retry( Attempts - 1, FC, Data, OnResponse, State, {unexpected_response, Response} )
      end;
    {error, Error}->
      ?LOGWARNING("send-receive error, request: ~p, error ~p",[ Request, Error ]),
      retry( Attempts - 1, FC, Data, OnResponse, State, Error )
  end.

retry( Attempts, FC, Data, OnResponse, State, _Error ) when Attempts > 0->
  ResetState = reset_link( State ),
  transaction( Attempts, FC, Data, OnResponse, ResetState );
retry( 0 = _Attempts, _FC, _Data, _OnResponse, _State, Error )->
  {error, Error}.



reset_link(#state{ attempts = Attempts } = State)->
  reset_link( Attempts, State ).

reset_link(Attempts, #state{
  address = Address,
  send_receive = SendReceive
} = State)->

  Request = request(?RESET_REMOTE_LINK, _Data = undefined, State),

  case SendReceive( Request ) of
    {ok, Response} ->
      case Response of
        #frame{ address = Address, control_field = #control_field_response{
          function_code = ?ACKNOWLEDGE
        }} ->
          {ok, State#state{ fcb = 1 }};
        _->
          ?LOGWARNING("unexpected response on reset link ~p, left attempts ~p",[Response, Attempts - 1]),
          reset_link(Attempts - 1, State )
      end;
    {error, Error}->
      ?LOGWARNING("reset link attempt error ~p, left attempts ~p",[Error, Attempts - 1]),
      reset_link(Attempts - 1, State )
  end;
reset_link(0 = _Attempts, _State)->
  {error, reset_link_error}.


request(FC, UserData, #state{
  address = Address,
  direction = Dir,
  fcb = FCB
})->

  #frame{
    address = Address,
    control_field = #control_field_request{
      direction = Dir,
      fcb = handle_fcb(FC, FCB),
      fcv = handle_fcv( FC ),
      function_code = FC
    },
    data = UserData
  }.

send_receive(Port, Request, Timeout)->
  Address = Request#frame.address,
  ok = iec60870_ft12:send(Port, Request),
  receive
    {data, Port, Response} ->
      case Response of
        #frame{address = Address, control_field = #control_field_response{}} ->
          {ok, Response};
        _->
          ?LOGWARNING("invalid response received, request ~p, response ~p", [Request, Response]),
          {error, invalid_response}
      end
  after
    Timeout-> {error, timeout}
  end.

handle_fcb(FC, FCB) ->
  case FC of
    ?RESET_REMOTE_LINK   -> 0;
    ?REQUEST_STATUS_LINK -> 0;
    _-> ?NOT(FCB)
  end.

handle_fcv(FC) ->
  case FC of
    ?REQUEST_DATA_CLASS_1 -> 1;
    ?REQUEST_DATA_CLASS_2 -> 1;
    ?USER_DATA_CONFIRM    -> 1;

    ?LINK_TEST         -> 1;

    _Other-> 0
  end.