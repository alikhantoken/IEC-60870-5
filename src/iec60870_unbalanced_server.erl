%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-module(iec60870_unbalanced_server).

-include("iec60870.hrl").
-include("ft12.hrl").
-include("function_codes.hrl").

%%% +--------------------------------------------------------------+
%%% |                             API                              |
%%% +--------------------------------------------------------------+

-export([
  start/2,
  stop/1
]).

%%% +--------------------------------------------------------------+
%%% |                       Macros & Records                       |
%%% +--------------------------------------------------------------+

-define(CONNECTION_TIMEOUT, 60000).

-define(ACKNOWLEDGE_FRAME(Address), #frame{
  address = Address,
  control_field = #control_field_response{
    direction = 0,
    acd = 0,
    dfc = 0,
    function_code = ?ACKNOWLEDGE
  }
}).

-record(data, {
  name,
  root,
  address,
  switch,
  fcb,
  sent_frame,
  connection
}).

%% +--------------------------------------------------------------+
%% |                       API implementation                     |
%% +--------------------------------------------------------------+

start(Root, Options) ->
  PID = spawn_link(fun() -> init(Root, Options) end),
  receive
    {ready, PID} ->
      PID;
    {'EXIT', PID, Reason} ->
      ?LOGERROR("failed to start, reason: ~p", [Reason]),
      throw(Reason)
  end.

stop(PID) ->
  catch exit(PID, shutdown).

%%% +--------------------------------------------------------------+
%%% |                      Internal functions                      |
%%% +--------------------------------------------------------------+

init(Root, #{
  transport := #{name := PortName},
  address := Address
} = Options) ->
  Switch = iec60870_switch:start(Options),
  iec60870_switch:add_server(Switch, Address),
  Root ! {ready, self()},
  Connection = start_connection(Root),
  ?LOGINFO("~p starting, root: ~p, link address: ~p", [PortName, Root, Address]),
  loop(#data{
    name = PortName,
    root = Root,
    address = Address,
    switch = Switch,
    connection = Connection,
    fcb = undefined
  }).

start_connection(Root) ->
  case iec60870_server:start_connection(Root, {?MODULE, self()}, self()) of
    {ok, NewConnection} ->
      NewConnection;
    error ->
      ?LOGERROR("failed to start server state machine, root: ~p", [Root]),
      exit({server_statem_start_failure, {self, self()}, {root, Root}})
  end.

loop(#data{
  name = Name,
  switch = Switch,
  address = Address,
  fcb = FCB,
  sent_frame = SentFrame
} = Data) ->
  receive
    {data, Switch, #frame{address = ReqAddress}} when ReqAddress =/= Address ->
      ?LOGWARNING("~p link address ~p received unexpected link address: ~p", [Name, Address, ReqAddress]),
      loop(Data);
    {data, Switch, Unexpected = #frame{control_field = #control_field_response{}}} ->
      ?LOGWARNING("~p link address ~p received unexpected response frame: ~p", [Name, Address, Unexpected]),
      loop(Data);
    {data, Switch, Frame = #frame{control_field = CF, data = UserData}} ->
      ?LOGDEBUG("~p link address ~p received frame: ~p", [Name, Address, Frame]),
      case check_fcb(CF, FCB) of
        {ok, NextFCB} ->
          Data1 = handle_request(CF#control_field_request.function_code, UserData, Data),
          loop(Data1#data{fcb = NextFCB});
        error ->
          ?LOGWARNING("~p link address ~p got check FCB error, CF: ~p, FCB: ~p", [Name, Address, CF, FCB]),
          case SentFrame of
            #frame{} -> send_response(Switch, SentFrame);
            _ -> ignore
          end,
          loop(Data)
      end
  after
    ?CONNECTION_TIMEOUT ->
      ?LOGWARNING("~p link address ~p connection timeout!", [Name, Address]),
      loop(Data)
  end.

check_fcb(#control_field_request{fcv = 0, fcb = _ReqFCB}, _FCB) ->
  {ok, 0}; %% TODO. Is it correct to treat fcv = 0 as a reset?
check_fcb(#control_field_request{fcv = 1, fcb = FCB}, FCB) ->
  error;
check_fcb(#control_field_request{fcv = 1, fcb = RecFCB}, _FCB) ->
  {ok, RecFCB}.

handle_request(?RESET_REMOTE_LINK, _UserData, #data{
  switch = Switch,
  address = Address,
  name = Name
} = Data) ->
  ?LOGDEBUG("~p link address ~p received [RESET LINK]", [Name, Address]),
  Data#data{
    sent_frame = send_response(Switch, ?ACKNOWLEDGE_FRAME(Address))
  };

handle_request(?RESET_USER_PROCESS, _UserData, #data{
  switch = Switch,
  address = Address,
  name = Name
} = Data) ->
  ?LOGDEBUG("~p link address ~p received [RESET USER PROCESS]", [Name, Address]),
  drop_asdu(),
  Data#data{
    sent_frame = send_response(Switch, ?ACKNOWLEDGE_FRAME(Address))
  };

handle_request(?USER_DATA_CONFIRM, ASDU, #data{
  connection = Connection,
  switch = Switch,
  address = Address,
  name = Name
} = Data) ->
  ?LOGDEBUG("~p link address ~p received [USER DATA CONFIRM]", [Name, Address]),
  Connection ! {asdu, self(), ASDU},
  Data#data{
    sent_frame = send_response(Switch, ?ACKNOWLEDGE_FRAME(Address))
  };

handle_request(?USER_DATA_NO_REPLY, ASDU, #data{
  connection = Connection,
  address = Address,
  name = Name
} = Data) ->
  ?LOGDEBUG("~p link address ~p received [USER DATA CONFIRM]", [Name, Address]),
  Connection ! {asdu, self(), ASDU},
  Data;

handle_request(?ACCESS_DEMAND, _UserData, #data{
  switch = Switch,
  address = Address,
  name = Name
} = Data) ->
  ?LOGDEBUG("~p link address ~p received [ACCESS DEMAND]", [Name, Address]),
  Data#data{
    sent_frame = send_response(Switch, #frame{
      address = Address,
      control_field = #control_field_response{
        direction = 0,
        acd = 0,
        dfc = 0,
        function_code = ?STATUS_LINK_ACCESS_DEMAND
      }
    })
  };

handle_request(?REQUEST_STATUS_LINK, _UserData, #data{
  switch = Switch,
  address = Address,
  name = Name
} = Data) ->
  ?LOGDEBUG("~p link address ~p received [REQUEST STATUS LINK]", [Name, Address]),
  Data#data{
    sent_frame = send_response(Switch, #frame{
      address = Address,
      control_field = #control_field_response{
        direction = 0,
        acd = 0,
        dfc = 0,
        function_code = ?STATUS_LINK_ACCESS_DEMAND
      }
    })
  };

handle_request(RequestData, _UserData, #data{
  switch = Switch,
  address = Address,
  name = Name
} = Data)
  when RequestData =:= ?REQUEST_DATA_CLASS_1;
       RequestData =:= ?REQUEST_DATA_CLASS_2 ->
  Response =
    case check_data() of
      {ok, ConnectionData} ->
        ?LOGDEBUG("~p link address ~p message queue: ~p", [
          Name,
          Address,
          element(2,erlang:process_info(self(), message_queue_len))
        ]),
        #frame{
          address = Address,
          control_field = #control_field_response{
            direction = 0,
            acd = 1,
            dfc = 0,
            function_code = ?USER_DATA
          },
          data = ConnectionData
        };
      _ ->
        %% Data isn't available
        #frame{
          address = Address,
          control_field = #control_field_response{
            direction = 0,
            acd = 0,
            dfc = 0,
            function_code = ?NACK_DATA_NOT_AVAILABLE
          }
        }
    end,
  ?LOGDEBUG("~p link address ~p received [DATA CLASS REQUEST], replying: ~p", [Name, Address, Response]),
  Data#data{
    sent_frame = send_response(Switch, Response)
  };

handle_request(InvalidFC, _UserData, #data{name = Name, address = Address} = Data) ->
  ?LOGERROR("~p link address ~p received invalid request function code: ~p", [Name, Address, InvalidFC]),
  Data.

send_response(Switch, Frame) ->
  Switch ! {send, self(), Frame},
  Frame.

check_data() ->
  receive
    {asdu, From, Reference, Data} ->
      From ! {confirm, Reference},
      {ok, Data}
  after
    0 -> undefined
  end.

drop_asdu() ->
  receive
    {asdu, From, Reference, _Data} ->
      From ! {confirm, Reference},
      drop_asdu()
  after
    0 -> ok
  end.