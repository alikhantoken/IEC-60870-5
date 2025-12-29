%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-module(iec60870_server_stm).
-behaviour(gen_statem).

-include("iec60870.hrl").
-include("iec60870_asdu.hrl").

%%% +--------------------------------------------------------------+
%%% |                     Server Process Tree                      |
%%% +--------------------------------------------------------------+
%%% |                  Server State Machine                        |
%%% |                      /          \                            |
%%% |           Update Queue          Send Queue                   |
%%% |                                          \                   |
%%% |                                          Connection          |
%%% +--------------------------------------------------------------+
%%% | Description:                                                 |
%%% |   - Server STM: handles events and acts as an orchestrator   |
%%% |      of the other processes in the tree                      |
%%% |   - Update queue: receives updates from esubscribe and       |
%%% |      handles group requests                                  |
%%% |   - Send queue: receives command functions from STM and      |
%%% |     updates from update queue to send to the connection      |
%%% |   - Connection: handles transport level communication        |
%%% | All processes are linked according to the tree               |
%%% +--------------------------------------------------------------+

%%% +--------------------------------------------------------------+
%%% |                            OTP API                           |
%%% +--------------------------------------------------------------+

-export([
  start_link/3,
  init/1,
  callback_mode/0,
  code_change/3,
  handle_event/4,
  terminate/3
]).

%%% +---------------------------------------------------------------+
%%% |                              API                              |
%%% +---------------------------------------------------------------+

-export([
  build_asdu/5
]).

%%% +---------------------------------------------------------------+
%%% |                         Macros & Records                      |
%%% +---------------------------------------------------------------+

-record(state, {
  root,
  groups,
  settings,
  connection,
  send_queue,
  update_queue,
  diagnostics
}).

-define(RUNNING, running).

%%% +--------------------------------------------------------------+
%%% |                  OTP behaviour implementation                |
%%% +--------------------------------------------------------------+

start_link(Connection, Diagnostics, Settings) ->
  gen_statem:start(?MODULE, [_Root = self(), Connection, Diagnostics, Settings], []).

init([
  Root,
  Connection,
  Diagnostics,
  #{
    name := Name,
    groups := Groups,
    storage := Storage,
    asdu := ASDUSettings
  } = Settings
]) ->
  process_flag(trap_exit, true),
  link(Connection),
  {ok, SendQueue} = iec60870_server_stm_send_queue:start_link(Name, Connection),
  {ok, UpdateQueue} = iec60870_server_stm_update_queue:start_link(Name, Storage, SendQueue, ASDUSettings),
  init_group_requests(Groups),
  iec60870_diagnostics:add(Diagnostics, self(),
    #{
      <<"connection">> => #{
        <<"configuration">> => ASDUSettings
      }
    }
  ),
  ?LOGINFO("~p starting state machine, root: ~p, connection: ~p", [Name, Root, Connection]),
  {ok, ?RUNNING, #state{
    root = Root,
    settings = Settings,
    connection = Connection,
    send_queue = SendQueue,
    update_queue = UpdateQueue,
    diagnostics = Diagnostics
  }}.

handle_event(enter, _PrevState, ?RUNNING, #state{settings = #{name := Name}} = _Data) ->
  ?LOGINFO("~p entering state - running", [Name]),
  keep_state_and_data;

%% Incoming packets from the connection
handle_event(info, {asdu, Connection, ASDU}, _AnyState, #state{
  settings = #{
    name := Name,
    asdu := ASDUSettings
  },
  connection = Connection
} = State)->
  try
    ParsedASDU = iec60870_asdu:parse(ASDU, ASDUSettings),
    handle_asdu(ParsedASDU, State)
  catch
    _Exception:Error ->
      ?LOGERROR("~p received invalid asdu: ~p, error: ~p", [Name, ASDU, Error]),
      keep_state_and_data
  end;

handle_event(info, {update_group, GroupID, Timer}, ?RUNNING, #state{
  update_queue = UpdateQueue
}) ->
  UpdateQueue ! {general_interrogation, self(), {update_group, GroupID}},
  timer:send_after(Timer, {update_group, GroupID, Timer}),
  keep_state_and_data;

handle_event(info, {'EXIT', PID, Reason}, _AnyState, #state{
  settings = #{
    name := Name
  }
}) ->
  ?LOGERROR("~p received EXIT from PID: ~p, reason: ~p", [Name, PID, Reason]),
  {stop, Reason};

handle_event(EventType, EventContent, _AnyState, #state{
  settings = #{
    name := Name
  }
}) ->
  ?LOGWARNING("~p received unexpected event: ~p, content: ~p", [
    Name, EventType, EventContent
  ]),
  keep_state_and_data.

terminate(Reason, _, #state{
  update_queue = UpdateQueue,
  send_queue = SendQueue,
  connection = Connection,
  diagnostics = Diagnostics,
  settings = #{
    name := Name
  }
}) ->
  catch exit(SendQueue, shutdown),
  catch exit(UpdateQueue, shutdown),
  catch exit(Connection, shutdown),
  iec60870_diagnostics:remove(Diagnostics, self()),
  ?LOGERROR("~p terminated w/ reason: ~p", [Name, Reason]),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

callback_mode() -> [
  handle_event_function,
  state_enter
].

%%% +--------------------------------------------------------------+
%%% |                      Internal functions                      |
%%% +--------------------------------------------------------------+

init_group_requests(Groups)  ->
  [begin
     timer:send_after(0, {update_group, GroupID, Millis})
   end || #{id := GroupID, update := Millis} <- Groups, is_integer(Millis)].

%% Receiving information data objects
handle_asdu(#asdu{
  type = Type,
  objects = Objects
}, #state{
  update_queue = UpdateQueuePID,
  settings = #{
    io_updates_enabled := IOUpdatesEnabled,
    storage := Storage,
    name := Name
  }
})
  when (Type >= ?M_SP_NA_1 andalso Type =< ?M_ME_ND_1)
    orelse (Type >= ?M_SP_TB_1 andalso Type =< ?M_EP_TD_1)
    orelse (Type =:= ?M_EI_NA_1) ->
  % When a command handler is defined, any information data objects should be ignored
  case IOUpdatesEnabled of
    true ->
      [begin
         NewObject = Object#{ type => Type },
         OldObject =
           case ets:lookup(Storage, IOA) of
             [{_, Map}] -> Map;
             _ -> #{type => Type, group => undefined}
           end,
         MergedObject = {IOA, iec60870_lib:merge_objects(OldObject, NewObject)},
         ets:insert(Storage, MergedObject),
         UpdateQueuePID ! {Name, update, MergedObject, none, UpdateQueuePID}
         end
        || {IOA, Object} <- Objects];
    false ->
      ignore
  end,
  keep_state_and_data;

%% Remote control commands
%% +--------------------------------------------------------------+
%% | Note: The write request on the server begins with the        |
%% | execution of the handler. It is asynchronous because we      |
%% | don't want to delay the work of the entire state machine.    |
%% | Handler must return {error, Error} or ok                     |
%% +--------------------------------------------------------------+

handle_asdu(#asdu{
  type = Type,
  objects = Objects
}, #state{
  settings = #{
    command_handler := Handler,
    asdu := ASDUSettings,
    root := ServerRef,
    name := Name
  }
} = State)
  when (Type >= ?C_SC_NA_1 andalso Type =< ?C_BO_NA_1)
    orelse (Type >= ?C_SC_TA_1 andalso Type =< ?C_BO_TA_1) ->
  if
    is_function(Handler) ->
      try
        [{IOA, Value}] = Objects,
        case Handler(ServerRef, Type, IOA, Value) of
          {error, HandlerError} ->
            ?LOGERROR("~p remote control handler returned error: ~p", [Name, HandlerError]),
            NegativeConfirmation = build_asdu(Type, ?COT_ACTCON, ?NEGATIVE_PN, Objects, ASDUSettings),
            send_asdu(?REMOTE_CONTROL_PRIORITY, NegativeConfirmation, State);
          ok ->
            %% +------------[ Activation confirmation ]-------------+
            Confirmation = build_asdu(Type, ?COT_ACTCON, ?POSITIVE_PN, Objects, ASDUSettings),
            send_asdu(?REMOTE_CONTROL_PRIORITY, Confirmation, State),
            %% +------------[ Activation termination ]--------------+
            Termination = build_asdu(Type, ?COT_ACTTERM, ?POSITIVE_PN, Objects, ASDUSettings),
            send_asdu(?REMOTE_CONTROL_PRIORITY, Termination, State)
        end
      catch
        _Exception:Error ->
          ?LOGERROR("~p remote control handler failed, error: ~p", [Name, Error]),
          %% +-------[ Negative activation confirmation ]---------+
          ExceptionNegConfirmation = build_asdu(Type, ?COT_ACTCON, ?NEGATIVE_PN, Objects, ASDUSettings),
          send_asdu(?REMOTE_CONTROL_PRIORITY, ExceptionNegConfirmation, State)
      end;
    true ->
      %% +-------[ Negative activation confirmation ]---------+
      ?LOGWARNING("~p remote control request accepted but no handler defined", [Name]),
      NegativeConfirmation = build_asdu(Type, ?COT_ACTCON, ?NEGATIVE_PN, Objects, ASDUSettings),
      send_asdu(?REMOTE_CONTROL_PRIORITY, NegativeConfirmation, State)
  end,
  keep_state_and_data;

%% General Interrogation Command
handle_asdu(#asdu{
  type = ?C_IC_NA_1,
  objects = [{_IOA, GroupID}]
}, #state{
  update_queue = UpdateQueue
}) ->
  UpdateQueue ! {general_interrogation, self(), GroupID},
  keep_state_and_data;

%% Counter Interrogation Command
handle_asdu(#asdu{
  type = ?C_CI_NA_1,
  objects = [{IOA, GroupID}]
}, #state{
  settings = #{
    asdu := ASDUSettings
  }
} = State) ->
  % TODO: Counter Interrogation is not supported
  [NegativeConfirmation] = iec60870_asdu:build(#asdu{
    type = ?C_CI_NA_1,
    pn = ?NEGATIVE_PN,
    cot = ?COT_ACTCON,
    objects = [{IOA, GroupID}]
  }, ASDUSettings),
  send_asdu(?COMMAND_PRIORITY, NegativeConfirmation, State),
  keep_state_and_data;

%% Clock Synchronization Command
handle_asdu(#asdu{
  type = ?C_CS_NA_1
}, #state{}) ->
  % TODO: Clock Synchronization is not supported
  % +-------------[ Send initialization ]-------------+
  keep_state_and_data;

%% All other unexpected asdu types
handle_asdu(#asdu{
  type = Type
}, #state{
  settings = #{name := Name}
}) ->
  ?LOGWARNING("~p received unsupported asdu type: ~p", [Name, Type]),
  keep_state_and_data.

send_asdu(Priority, ASDU, #state{
  send_queue = SendQueue
}) ->
  SendQueue ! {send_no_confirm, self(), Priority, ASDU}.

build_asdu(Type, COT, PN, Objects, Settings) ->
  [Packet] = iec60870_asdu:build(#asdu{
    type = Type,
    cot = COT,
    pn = PN,
    objects = Objects
  }, Settings),
  Packet.