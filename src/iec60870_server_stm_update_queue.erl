%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2025. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-module(iec60870_server_stm_update_queue).
-include("iec60870.hrl").
-include("asdu.hrl").

%%% +--------------------------------------------------------------+
%%% |                            API                               |
%%% +--------------------------------------------------------------+

-export([
  start_link/4
]).

%%% +---------------------------------------------------------------+
%%% |                         Macros & Records                      |
%%% +---------------------------------------------------------------+

-record(pointer, {priority, cot, type}).
-record(order, {pointer, ioa, ts}).
-record(update_state, {
  owner,
  name,
  tickets,
  index_ets,
  update_queue_ets,
  history_queue_ets,
  send_queue_pid,
  asdu_settings,
  pointer,
  storage,
  group
}).

-define(START_OF_TABLE, -1).

%%% +--------------------------------------------------------------+
%%% |                     Update Queue Process                     |
%%% +--------------------------------------------------------------+
%%% | Description: update queue process is responsible only for    |
%%% | the incoming updates from the esubscribe and handling GI     |
%%% | requests from the server state machine process               |
%%% +--------------------------------------------------------------+

start_link(Name, Storage, SendQueue, ASDUSettings) ->
  Owner = self(),
  {ok, spawn_link(
    fun() ->
      esubscribe:subscribe(Name, update, self()),
      IndexETS = ets:new(index, [
        set,
        private
      ]),
      HistoryQueue = ets:new(history_queue, [
        set,
        private
      ]),
      UpdateQueue = ets:new(update_queue, [
        ordered_set,
        private
      ]),
      ?LOGINFO("~p starting update queue...", [Name]),
      update_queue(#update_state{
        owner = Owner,
        name = Name,
        storage = Storage,
        index_ets = IndexETS,
        update_queue_ets = UpdateQueue,
        history_queue_ets = HistoryQueue,
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
        GroupUpdates = collect_gi_updates(Group, Storage),
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
        GroupUpdates = collect_gi_updates(Group, Storage),
        [enqueue_update(?COMMAND_PRIORITY, ?COT_GROUP(Group), {IOA, DataObject}, InState)
          || {IOA, DataObject} <- GroupUpdates],
        case GroupUpdates of
          [] ->
            Termination = build_gi_termination(Group, ASDUSettings),
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

enqueue_update(Priority, COT, {IOA, #{type := Type} = DataObject}, #update_state{
  history_queue_ets = HistoryQueue,
  update_queue_ets = UpdateQueue,
  index_ets = IndexETS
}) ->
  Order = #order{
    pointer = #pointer{priority = Priority, cot = COT, type = Type},
    ioa = IOA,
    ts = undefined
  },
  case DataObject of
    #{ts := Timestamp} ->
      ets:insert(UpdateQueue, {Order, true}),
      ets:insert(HistoryQueue, {{IOA, Timestamp}, Order#order{ts = Timestamp}});
    _Other ->
      case ets:lookup(IndexETS, IOA) of
        [] ->
          ets:insert(UpdateQueue, {Order, true}),
          ets:insert(IndexETS, {IOA, Order});
        [{_, #order{pointer = #pointer{priority = HasPriority}}}] when HasPriority < Priority ->
          ?LOGDEBUG("ignore update ioa: ~p, priority: ~p, has priority: ~p", [IOA, Priority, HasPriority]),
          ignore;
        [{_, PrevOrder}] ->
          ets:delete(UpdateQueue, PrevOrder),
          ets:insert(UpdateQueue, {Order, true}),
          ets:insert(IndexETS, {IOA, Order})
      end
  end.

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
  
get_pointer_updates(NextPointer, #update_state{
  update_queue_ets = UpdateQueue
} = State) ->
  InitialOrder = #order{pointer = NextPointer, ioa = ?START_OF_TABLE, ts = ?START_OF_TABLE},
  InitialKey = ets:next(UpdateQueue, InitialOrder),
  get_pointer_updates(InitialKey, NextPointer, State).
get_pointer_updates(#order{pointer = NextPointer, ioa = IOA, ts = undefined} = Order, NextPointer, #update_state{
  update_queue_ets = UpdateQueue,
  index_ets = Index,
  storage = Storage
} = State) ->
  ets:delete(UpdateQueue, Order),
  ets:delete(Index, IOA),
  NextOrder = ets:next(UpdateQueue, Order),
  case ets:lookup(Storage, IOA) of
    [Update] ->
      [Update | get_pointer_updates(NextOrder, NextPointer, State)];
    [] ->
      get_pointer_updates(NextOrder, NextPointer, State)
  end;
get_pointer_updates(#order{pointer = NextPointer, ioa = IOA, ts = Timestamp} = Order, NextPointer, #update_state{
  update_queue_ets = UpdateQueue,
  history_queue_ets = HistoryQueue
} = State) ->
  ets:delete(UpdateQueue, Order),
  NextOrder = ets:next(UpdateQueue, Order),
  Result =
    case ets:lookup(HistoryQueue, {IOA, Timestamp}) of
      [Update] ->
        [Update | get_pointer_updates(NextOrder, NextPointer, State)];
      [] ->
        get_pointer_updates(NextOrder, NextPointer, State)
    end,
  ets:delete(HistoryQueue, {IOA, Timestamp}),
  Result;
get_pointer_updates(_NextOrder, _NextPointer, _State) ->
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

send_update(SendQueue, Priority, ASDU) ->
  ?LOGDEBUG("enqueue asdu: ~p",[ASDU]),
  SendQueue ! {send_confirm, self(), Priority, ASDU},
  receive {accepted, TicketRef} -> TicketRef end.

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

collect_gi_updates(GroupID, Storage) ->
  case GroupID of
    ?GLOBAL_GROUP ->
      ets:tab2list(Storage);
    Group when Group >= ?START_GROUP andalso Group =< ?END_GROUP ->
      ets:match_object(Storage, {'_', #{group => GroupID}});
    _ ->
      []
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
      Termination = build_gi_termination(GroupID, ASDUSettings),
      SendQueuePID ! {send_no_confirm, self(), ?COMMAND_PRIORITY, Termination},
      State#update_state{group = undefined}
  end;
check_gi_termination(State) ->
  State.

build_gi_termination(GroupID, ASDUSettings) ->
  iec60870_server_stm:build_asdu(?C_IC_NA_1, ?COT_ACTTERM, ?POSITIVE_PN, [{0, GroupID}], ASDUSettings).