%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-module(iec60870_balanced).

-include("iec60870.hrl").
-include("iec60870_ft12.hrl").
-include("iec60870_function_codes.hrl").

%%% +--------------------------------------------------------------+
%%% |                            API                               |
%%% +--------------------------------------------------------------+

-export([
  start/2,
  stop/1
]).

%%% +--------------------------------------------------------------+
%%% |                       Macros & Records                       |
%%% +--------------------------------------------------------------+

-define(ACKNOWLEDGE_FRAME(Address, Direction),#frame{
  address = Address,
  control_field = #control_field_response{
    direction = Direction,
    acd = 0,
    dfc = 0,
    function_code = ?ACKNOWLEDGE
  }
}).

-define(TIMESTAMP, erlang:system_time(millisecond)).
-define(DURATION(T), (?TIMESTAMP - T)).

-record(data, {
  owner,
  address,
  direction,
  port,
  state,
  connection
}).

%%% +--------------------------------------------------------------+
%%% |                      API implementation                      |
%%% +--------------------------------------------------------------+

start(Direction, Options) ->
  Owner = self(),
  PID = spawn_link(fun() -> init(Owner, Direction, Options) end),
  receive
    {ready, PID} -> PID;
    {'EXIT', PID, Reason} -> throw(Reason)
  end.

stop(PID) ->
  catch exit(PID, shutdown).

%%% +--------------------------------------------------------------+
%%% |                      Internal functions                      |
%%% +--------------------------------------------------------------+

init(Owner, Direction, #{
  address := Address,
  timeout := Timeout,
  attempts := Attempts
} = Options) ->
  PortFT12 = iec60870_ft12:start_link(maps:with([transport, address_size], Options)),
  Owner ! {ready, self()},
  Data = #data{
    owner = Owner,
    address = Address,
    direction = Direction,
    port = PortFT12
  },
  case iec60870_101:connect(#{
    address => Address,
    timeout => Timeout,
    portFT12 => PortFT12,
    direction => Direction,
    attempts => Attempts,
    on_request =>
      fun(#frame{control_field = #control_field_request{function_code = FC}, data = UserData}) ->
        handle_request(FC, UserData, Data)
      end
  }) of
    error ->
      exit({error, connect_fail});
    State ->
      Owner ! {connected, self()},
      Connection =
        receive
          {connection, Owner, _Connection} -> _Connection
        end,
      send_delayed_asdu(Connection),
      loop(Data#data{
        state = State,
        connection = Connection
      })
  end.

send_delayed_asdu(Connection) ->
  receive
    {asdu, Self, ASDU} when Self =:= self() ->
      Connection ! {asdu, Self, ASDU},
      send_delayed_asdu(Connection)
  after
    0 -> ok
  end.

loop(#data{
  owner = Owner,
  port = Port,
  address = Address,
  connection = Connection,
  state = State
} = Data) ->
  receive
    {data, Port, #frame{address = ReqAddress}} when ReqAddress =/= Address ->
      loop(Data);
    {data, Port, #frame{control_field = #control_field_request{} = CF, data = UserData}} ->
      case check_fcb(CF) of
        ok ->
          Data1 = handle_request(CF#control_field_request.function_code, UserData, Data),
          loop(Data1);
        error ->
          ?LOGWARNING("check fcb error, cf ~p", [CF]),
          % On error we have to repeat the last sent frame
          case get(sent_frame) of
            RepeatFrame = #frame{} ->
              % On error we should repeat the last sent frame
              iec60870_ft12:send(Port, RepeatFrame);
            _ ->
              ignore
          end,
          loop(Data)
      end;
    {asdu, Connection, Reference, ASDU} ->
      Owner ! {confirm, Reference},
      NewState =
        case iec60870_101:user_data_confirm(ASDU, State) of
          error ->
            ?LOGERROR("~p failed to send asdu: ", [Address, ASDU]),
            Owner ! {send_error, self(), timeout},
            State;
          State1 ->
            ?LOGDEBUG("~p balanced sent user asdu: ", [Address, ASDU]),
            State1
        end,
      loop(Data#data{state = NewState});
    Unexpected ->
      ?LOGWARNING("unexpected message ~p", [Unexpected]),
      loop(Data)
  end.

%% FCB - Frame count bit
%% Alternated between 0 to 1 for successive SEND / CONFIRM or
%% REQUEST / RESPOND transmission procedures
check_fcb(#control_field_request{fcv = 0, fcb = _ReqFCB}) ->
  % TODO. Is it correct to treat fcv = 0 as a reset?
  put(fcb, 0),
  ok;
check_fcb(#control_field_request{fcv = 1, fcb = FCB}) ->
  case get(fcb) of
    FCB ->
      % FCB must not be the same
      error;
    NextFCB ->
      put(fcb, NextFCB),
      ok
  end.

handle_request(?RESET_REMOTE_LINK, _UserData, #data{
  port = Port,
  address = Address,
  direction = Direction
}) ->
  send_response(Port, ?ACKNOWLEDGE_FRAME(Address, Direction));

handle_request(?RESET_USER_PROCESS, _UserData, #data{
  port = Port,
  address = Address,
  direction = Direction
}) ->
  send_response(Port, ?ACKNOWLEDGE_FRAME(Address, Direction));

handle_request(?USER_DATA_CONFIRM, ASDU, #data{
  connection = Connection,
  port = Port,
  address = Address,
  direction = Direction
}) ->
  if
    is_pid(Connection) ->
      Connection ! {asdu, self(), ASDU};
    true ->
      self() ! {asdu, self(), ASDU}
  end,
  send_response(Port, ?ACKNOWLEDGE_FRAME(Address, Direction));

handle_request(?USER_DATA_NO_REPLY, ASDU, #data{
  connection = Connection
}) ->
  if
    is_pid(Connection) ->
      Connection ! {asdu, self(), ASDU};
    true ->
      self() ! {asdu, self(), ASDU}
  end,
  ok;

handle_request(?ACCESS_DEMAND, _UserData, #data{
  port = Port,
  address = Address,
  direction = Direction
})->
  send_response(Port, #frame{
    address = Address,
    control_field = #control_field_response{
      direction = Direction,
      acd = 0,
      dfc = 0,
      function_code = ?STATUS_LINK_ACCESS_DEMAND
    }
  });

handle_request(?REQUEST_STATUS_LINK, _UserData, #data{
  port = Port,
  address = Address,
  direction = Direction
}) ->
  send_response(Port, #frame{
    address = Address,
    control_field = #control_field_response{
      direction = Direction,
      acd = 0,
      dfc = 0,
      function_code = ?STATUS_LINK_ACCESS_DEMAND
    }
  });

handle_request(InvalidFC, _UserData, _Data) ->
  ?LOGERROR("invalid request function code received ~p", [InvalidFC]),
  ok.

send_response(Port, Frame) ->
  iec60870_ft12:send(Port, Frame),
  put(sent_frame, Frame),
  ok.