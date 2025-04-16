%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-module(iec60870_server_stm).
-behaviour(gen_statem).

-include("iec60870.hrl").
-include("asdu.hrl").

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
  callback_mode/0,
  code_change/3,
  init/1,
  handle_event/4,
  terminate/3
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
  update_queue
}).


-record(send_state, {
  owner,
  name,
  tickets,
  update_queue_pid,
  send_queue,
  connection,
  counter
}).

-define(ACCUMULATED_COTs, [?COT_SPONT]).

-define(REMOTE_CONTROL_PRIORITY, 0).
-define(COMMAND_PRIORITY, 1).
-define(UPDATE_PRIORITY, 2).

-define(GLOBAL_GROUP, 0).
-define(START_GROUP, 1).
-define(END_GROUP, 16).

-define(ESUBSCRIBE_DELAY, 100).

%% States
-define(RUNNING, running).

%%% +--------------------------------------------------------------+
%%% |                  OTP behaviour implementation                |
%%% +--------------------------------------------------------------+

callback_mode() -> [
  handle_event_function,
  state_enter
].

init({Root, Connection, #{
  name := Name,
  groups := Groups,
  storage := Storage,
  asdu := ASDUSettings
} = Settings}) ->
  process_flag(trap_exit, true),
  link(Connection),
  ?LOGINFO("~p starting state machine, root: ~p, connection: ~p", [Name, Root, Connection]),
  {ok, SendQueue} = start_link_send_queue(Name, Connection),
  {ok, UpdateQueue} = start_link_update_queue(Name, Storage, SendQueue, ASDUSettings),
  init_group_requests(Groups),
  {ok, ?RUNNING, #state{
    root = Root,
    settings = Settings,
    connection = Connection,
    send_queue = SendQueue,
    update_queue = UpdateQueue
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
  settings = #{
    name := Name
  }
}) ->
  catch exit(SendQueue, shutdown),
  catch exit(UpdateQueue, shutdown),
  catch exit(Connection, shutdown),
  ?LOGERROR("~p terminated w/ reason: ~p", [Name, Reason]),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

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
         {IOA, NewObject} = Object,
         OldObject =
           case ets:lookup(Storage, IOA) of
             [{_, Map}] -> Map;
             _ -> #{type => Type, group => undefined}
           end,
         MergedObject = {IOA, maps:merge(OldObject, NewObject)},
         ets:insert(Storage, MergedObject),
         UpdateQueuePID ! {Name, update, MergedObject, none, UpdateQueuePID}
         end
        || Object <- Objects];
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

%%% +--------------------------------------------------------------+
%%% |                     Update Queue Process                     |
%%% +--------------------------------------------------------------+
%%% | Description: update queue process is responsible only for    |
%%% | the incoming updates from the esubscribe and handling GI     |
%%% | requests from the server state machine process               |
%%% +--------------------------------------------------------------+

-record(update_state, {
  owner,
  name,
  tickets,
  update_queue_ets,
  ioa_index,
  send_queue_pid,
  asdu_settings,
  pointer,
  storage,
  group
}).

start_link_update_queue(Name, Storage, SendQueue, ASDUSettings) ->
  Owner = self(),
  {ok, spawn_link(
    fun() ->
      esubscribe:subscribe(Name, update, self()),
      UpdateQueue = ets:new(update_queue, [
        ordered_set,
        private
      ]),
      IndexIOA = ets:new(io_index, [
        set,
        private
      ]),
      ?LOGINFO("~p starting update queue...", [Name]),
      update_queue(#update_state{
        owner = Owner,
        name = Name,
        storage = Storage,
        update_queue_ets = UpdateQueue,
        ioa_index = IndexIOA,
        send_queue_pid = SendQueue,
        asdu_settings = ASDUSettings,
        pointer = ets:first(UpdateQueue),
        tickets = #{},
        group = undefined
      })
    end)}.

update_queue(#update_state{
  name = Name,
  owner = Owner,
  tickets = Tickets,
  storage = Storage,
  send_queue_pid = SendQueuePID,
  asdu_settings = ASDUSettings,
  group = CurrentGroup
} = InState) ->
  State =
    receive
      % Real-time updates from esubscribe
      {Name, update, Update, _, Actor} ->
        if
          Actor =/= Owner ->
            enqueue_update(?UPDATE_PRIORITY, ?COT_SPONT, Update, InState);
          true ->
            ignore
        end,
        InState;

      % Confirmation of the ticket reference from
      {confirm, TicketRef} ->
        InState#update_state{tickets = maps:remove(TicketRef, Tickets)};

      % Ignoring group update event from STM
      {general_interrogation, Owner, {update_group, _Group}} when is_integer(CurrentGroup) ->
        InState;

      % Response to the general interrogation while being in the state of general interrogation
      {general_interrogation, Owner, Group} when is_integer(CurrentGroup) ->
        % If the group is the same, then GI is confirmed.
        % Otherwise, it is rejected.
        PN =
          case Group of
            CurrentGroup -> ?POSITIVE_PN;
            _Other -> ?NEGATIVE_PN
          end,
        ?LOGDEBUG("~p received general interrogation to group ~p while handling other gi group ~p, pn: ~p", [
          Name,
          Group,
          CurrentGroup,
          PN
        ]),
        [Confirmation] = iec60870_asdu:build(#asdu{
          type = ?C_IC_NA_1,
          pn = PN,
          cot = ?COT_ACTCON,
          objects = [{_IOA = 0, Group}]
        }, ASDUSettings),
        SendQueuePID ! {send_no_confirm, self(), ?COMMAND_PRIORITY, Confirmation},
        InState;

      % Handling general update event from the STM
      {general_interrogation, Owner, {update_group, Group}} ->
        GroupUpdates = collect_group_updates(Group, Storage),
        [enqueue_update(?COMMAND_PRIORITY, ?COT_SPONT, {IOA, DataObject}, InState)
          || {IOA, DataObject} <- GroupUpdates],
        InState;

      % Handling general interrogation from the connection
      {general_interrogation, Owner, Group} ->
        ?LOGDEBUG("~p received general interrogation, group: ~p", [Name, Group]),
        [Confirmation] = iec60870_asdu:build(#asdu{
          type = ?C_IC_NA_1,
          pn = ?POSITIVE_PN,
          cot = ?COT_ACTCON,
          objects = [{_IOA = 0, Group}]
        }, ASDUSettings),
        SendQueuePID ! {send_no_confirm, self(), ?COMMAND_PRIORITY, Confirmation},
        GroupUpdates = collect_group_updates(Group, Storage),
        [enqueue_update(?COMMAND_PRIORITY, ?COT_GROUP(Group), {IOA, DataObject}, InState)
          || {IOA, DataObject} <- GroupUpdates],
        case GroupUpdates of
          [] ->
            Termination = build_termination(Group, ASDUSettings),
            SendQueuePID ! {send_no_confirm, self(), ?COMMAND_PRIORITY, Termination},
            InState;
          _ ->
            InState#update_state{group = Group}
        end;

      Unexpected ->
        ?LOGWARNING("~p received unexpected message: ~p", [Name, Unexpected]),
        InState
    end,
  OutState = check_tickets(State),
  update_queue(OutState).

%%% +--------------------------------------------------------------+
%%% |                      Helper functions                        |
%%% +--------------------------------------------------------------+

-record(pointer, {priority, cot, type}).
-record(order, {pointer, ioa, id}).

check_tickets(#update_state{
  tickets = Tickets
} = State) when map_size(Tickets) > 0 ->
  State;
check_tickets(InState) ->
  NextPointer = next_queue(InState),
  case NextPointer of
    '$end_of_table' ->
      InState;
    NextPointer ->
      ?LOGDEBUG("next pointer: ~p", [NextPointer]),
      Updates = get_pointer_updates(NextPointer, InState),
      ?LOGDEBUG("pointer updates: ~p", [Updates]),
      State = send_updates(Updates, NextPointer, InState),
      check_gi_termination(State)
  end.

next_queue(#update_state{
  pointer = '$end_of_table',
  update_queue_ets = UpdateQueue
}) ->
  case ets:first(UpdateQueue) of
    #order{pointer = Pointer} -> Pointer;
    _ -> '$end_of_table'
  end;
next_queue(#update_state{
  pointer = #pointer{} = Pointer,
  update_queue_ets = UpdateQueue
} = State) ->
  case ets:next(UpdateQueue, #order{pointer = Pointer, ioa = max_ioa}) of
    #order{pointer = NextPointer} ->
      NextPointer;
    _Other ->
      % Start from the beginning
      next_queue(State#update_state{pointer = '$end_of_table'})
  end.

check_gi_termination(#update_state{
  pointer = #pointer{cot = COT},
  group = GroupID,
  send_queue_pid = SendQueuePID,
  asdu_settings = ASDUSettings
} = State) when (COT >= ?COT_GROUP_MIN andalso COT =< ?COT_GROUP_MAX) ->
  case next_queue(State) of
    #pointer{cot = COT} ->
      State;
    _Other ->
      Termination = build_termination(GroupID, ASDUSettings),
      SendQueuePID ! {send_no_confirm, self(), ?COMMAND_PRIORITY, Termination},
      State#update_state{group = undefined}
  end;
check_gi_termination(State) ->
  State.

get_pointer_updates(NextPointer, #update_state{
  update_queue_ets = UpdateQueue
} = State) ->
  get_pointer_updates(ets:next(UpdateQueue, #order{pointer = NextPointer, ioa = -1, id = undefined}), NextPointer, State).

get_pointer_updates(#order{pointer = NextPointer, ioa = IOA} = Order, NextPointer, #update_state{
  update_queue_ets = UpdateQueue,
  ioa_index = IndexIOA,
  storage = Storage
} = State) ->
  ets:delete(UpdateQueue, Order),
  ets:delete(IndexIOA, IOA),
  case ets:lookup(Storage, IOA) of
    [Update] ->
      [Update | get_pointer_updates(ets:next(UpdateQueue, Order), NextPointer, State)];
    [] ->
      get_pointer_updates(ets:next(UpdateQueue, Order), NextPointer, State)
  end;
get_pointer_updates(_NextKey, _NextPointer, _State) ->
  [].

send_updates(Updates, #pointer{
  priority = Priority,
  type = Type,
  cot = COT
} = Pointer, #update_state{
  asdu_settings = ASDUSettings,
  send_queue_pid = SendQueuePID
} = State) ->
  ListASDU = iec60870_asdu:build(#asdu{
    type = Type,
    cot = COT,
    pn = ?POSITIVE_PN,
    objects = Updates
  }, ASDUSettings),
  Tickets = lists:foldl(
    fun(ASDU, AccIn) ->
      Ticket = send_update(SendQueuePID, Priority, ASDU),
      AccIn#{Ticket => wait}
    end, #{}, ListASDU),
  State#update_state{
    tickets = Tickets,
    pointer = Pointer
  }.

collect_group_updates(GroupID, Storage) ->
  case GroupID of
    ?GLOBAL_GROUP ->
      ets:tab2list(Storage);
    Group when Group >= ?START_GROUP andalso Group =< ?END_GROUP ->
      ets:match_object(Storage, {'_', #{group => GroupID}});
    _ ->
      []
  end.

send_update(SendQueue, Priority, ASDU) ->
  ?LOGDEBUG("enqueue asdu: ~p",[ASDU]),
  SendQueue ! {send_confirm, self(), Priority, ASDU},
  receive {accepted, TicketRef} -> TicketRef end.

enqueue_update(Priority, COT, {IOA, #{type := Type}}, #update_state{
  ioa_index = IndexIOA,
  update_queue_ets = UpdateQueue
}) ->
  MultipleAllowed = lists:member(COT, ?ACCUMULATED_COTs),

  UniqueID =
    case MultipleAllowed of
      true ->
        erlang:unique_integer([monotonic, positive]);
      false ->
        undefined
    end,

  Order = #order{
    pointer = #pointer{priority = Priority, cot = COT, type = Type},
    ioa = IOA,
    id = UniqueID
  },

  case ets:lookup(IndexIOA, IOA) of
    [] ->
      ets:insert(UpdateQueue, {Order, true}),
      ets:insert(IndexIOA, {IOA, Order});

    [{_, #order{pointer = #pointer{priority = HasPriority}}}] when HasPriority < Priority, not MultipleAllowed ->
      ?LOGDEBUG("ignore update ioa: ~p, priority: ~p, has priority: ~p", [IOA, Priority, HasPriority]),
      ignore;

    [{_, PrevOrder}] when not MultipleAllowed ->
      ets:delete(UpdateQueue, PrevOrder),
      ets:insert(UpdateQueue, {Order, true}),
      ets:insert(IndexIOA, {IOA, Order});

    _ -> %% AllowMultiple = true case, always insert
      ets:insert(UpdateQueue, {Order, true}),
      ets:insert(IndexIOA, {IOA, Order})
  end.

build_termination(GroupID, ASDUSettings) ->
  build_asdu(?C_IC_NA_1, ?COT_ACTTERM, ?POSITIVE_PN, [{0, GroupID}], ASDUSettings).

%%% +--------------------------------------------------------------+
%%% |                      Send Queue Process                      |
%%% +--------------------------------------------------------------+
%%% | Description: send queue process is ONLY responsible for      |
%%% | sending data from state machine process to the connection    |
%%% | process (i.e. transport level).                              |
%%% +--------------------------------------------------------------+
%%% | Send queue ETS format: {Priority, Ref} => ASDU               |
%%% +--------------------------------------------------------------+

start_link_send_queue(Name, Connection) ->
  Owner = self(),
  {ok, spawn_link(
    fun() ->
      SendQueue = ets:new(send_queue, [
        ordered_set,
        private
      ]),
      ?LOGINFO("~p starting send queue...", [Name]),
      send_queue(#send_state{
        owner = Owner,
        name = Name,
        send_queue = SendQueue,
        connection = Connection,
        tickets = #{},
        counter = 0
      })
    end)}.

send_queue(#send_state{
  send_queue = SendQueue,
  name = Name,
  tickets = Tickets,
  counter = Counter
} = InState) ->
  State =
    receive
      {confirm, Reference} ->
        return_confirmation(Tickets, Reference),
        InState#send_state{tickets = maps:remove(Reference, Tickets)};
      {send_confirm, Sender, Priority, ASDU} ->
        Sender ! {accepted, Counter},
        ets:insert(SendQueue, {{Priority, Counter}, {Sender, ASDU}}),
        InState#send_state{counter = Counter + 1};
      {send_no_confirm, _Sender, Priority, ASDU} ->
        ets:insert(SendQueue, {{Priority, Counter}, {none, ASDU}}),
        InState#send_state{counter = Counter + 1};
      Unexpected ->
        ?LOGWARNING("~p received unexpected message: ~p", [Name, Unexpected]),
        InState
    end,
  OutState = check_send_queue(State),
  send_queue(OutState).

check_send_queue(#send_state{
  send_queue = SendQueue,
  connection = Connection,
  tickets = Tickets
} = InState) when map_size(Tickets) =:= 0 ->
  case ets:first(SendQueue) of
    '$end_of_table' ->
      InState;
    {_Priority, Reference} = Key ->
      % We save the ticket to wait for confirmation for this process
      [{_Key, {Sender, ASDU}}] = ets:take(SendQueue, Key),
      send_to_connection(Connection, Reference, ASDU),
      InState#send_state{tickets = Tickets#{Reference => Sender}}
  end;
check_send_queue(#send_state{} = State) ->
  State.

%%% +--------------------------------------------------------------+
%%% |                      Helper functions                        |
%%% +--------------------------------------------------------------+

return_confirmation(Tickets, Reference) ->
  case Tickets of
    #{Reference := Sender} when is_pid(Sender) ->
      Sender ! {confirm, Reference};
    _Other ->
      ok
  end.

send_to_connection(Connection, Reference, ASDU) ->
  Connection ! {asdu, self(), Reference, ASDU}.