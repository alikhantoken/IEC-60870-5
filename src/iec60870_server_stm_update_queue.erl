%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2025. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-module(iec60870_server_stm_update_queue).
-include("iec60870.hrl").
-include("asdu.hrl").

-export([start_link/4]).

%%% +--------------------------------------------------------------+
%%% |                         Macros & Records                     |
%%% +--------------------------------------------------------------+

-define(START_OF_TABLE, -1).
-define(END_OF_TABLE, '$end_of_table').

-define(GLOBAL_GROUP, 0).
-define(START_GROUP, 1).
-define(END_GROUP, 16).

-record(state, {
  owner,
  name,
  tickets,
  update_queue_ets,
  index_ets,
  history_queue_ets,
  send_queue_pid,
  asdu_settings,
  pointer,
  storage,
  group
}).

-record(pointer, {
  priority,
  cot,
  type
}).

-record(order, {
  pointer,
  ioa
}).

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
      Index = ets:new(index, [
        set,
        private
      ]),
      UpdateQueueSet = ets:new(updates, [
        ordered_set,
        private
      ]),
      HistoryBag = ets:new(history, [
        bag,
        private
      ]),
      ?LOGINFO("~p starting update queue...", [Name]),
      loop(#state{
        owner = Owner,
        name = Name,
        storage = Storage,
        index_ets = Index,
        update_queue_ets = UpdateQueueSet,
        history_queue_ets = HistoryBag,
        send_queue_pid = SendQueue,
        asdu_settings = ASDUSettings,
        pointer = ets:first(UpdateQueueSet),
        tickets = #{},
        group = undefined
      })
    end)}.

loop(#state{
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
        InState#state{tickets = maps:remove(TicketRef, Tickets)};

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
        GroupUpdates = gi_get_updates(Group, Storage),
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
        GroupUpdates = gi_get_updates(Group, Storage),
        [enqueue_update(?COMMAND_PRIORITY, ?COT_GROUP(Group), {IOA, DataObject}, InState)
          || {IOA, DataObject} <- GroupUpdates],
        case GroupUpdates of
          [] ->
            Termination = gi_build_termination(Group, ASDUSettings),
            SendQueuePID ! {send_no_confirm, self(), ?COMMAND_PRIORITY, Termination},
            InState;
          _ ->
            InState#state{group = Group}
        end;

      Unexpected ->
        ?LOGWARNING("~p received unexpected message: ~p", [Name, Unexpected]),
        InState
    end,
  OutState = check_tickets(State),
  loop(OutState).

%%% +--------------------------------------------------------------+
%%% |                      Helper functions                        |
%%% +--------------------------------------------------------------+

enqueue_update(Priority, COT, {IOA, #{type := Type} = DataObject}, #state{
  index_ets = Index,
  history_queue_ets = HistoryQueueBag,
  update_queue_ets = UpdateQueueSet
}) ->
  Order = #order{
    pointer = #pointer{priority = Priority, cot = COT, type = Type},
    ioa = IOA
  },
  case DataObject of
    #{ts := _Timestamp} ->
      ets:insert(HistoryQueueBag, {IOA, DataObject});
    _NoTS ->
      ignore
  end,
  case ets:lookup(Index, IOA) of
    [] ->
      ?LOGDEBUG("ioa: ~p, priority: ~p",[ IOA, Priority ]),
      ets:insert(UpdateQueueSet, {Order, true}),
      ets:insert(Index, {IOA, Order});
    [{_, #order{pointer = #pointer{priority = HasPriority}}}] when HasPriority < Priority ->
      % We cannot lower the existing priority
      ?LOGDEBUG("ignore update ioa: ~p, priority: ~p, has prority: ~p",[ IOA, Priority, HasPriority ]),
      ignore;
    [{ _, PrevOrder}] ->
      ?LOGDEBUG("ioa: ~p, priority: ~p, previous order: ~p",[ IOA, Priority, PrevOrder ]),
      ets:delete(UpdateQueueSet, PrevOrder),
      ets:insert(UpdateQueueSet, {Order, true}),
      ets:insert(Index, {IOA, Order})
  end.

check_tickets(#state{
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
      gi_check_termination(State)
  end.
  
get_pointer_updates(NextPointer, #state{
  update_queue_ets = UpdateQueueSet
} = State) ->
  InitialOrder = #order{pointer = NextPointer, ioa = ?START_OF_TABLE},
  InitialKey = ets:next(UpdateQueueSet, InitialOrder),
  lists:append(get_pointer_updates(InitialKey, NextPointer, State)).
get_pointer_updates(#order{pointer = NextPointer, ioa = IOA} = Order, NextPointer, #state{
  update_queue_ets = UpdateQueueSet,
  history_queue_ets = HistoryQueueBag,
  index_ets = Index,
  storage = Storage
} = State) ->
  ets:delete(UpdateQueueSet, Order),
  ets:delete(Index, IOA),
  NextOrder = ets:next(UpdateQueueSet, Order),
  HistoryUpdates =
    lists:sort(
      fun({_, #{accept_ts := AcceptTSa, ts := TSa}}, {_, #{accept_ts := AcceptTSb, ts := TSb}}) ->
        AcceptTSa < AcceptTSb orelse (AcceptTSa =:= AcceptTSb andalso TSa < TSb)
      end,
      ets:take(HistoryQueueBag, IOA)
    ),
  PointerUpdates =
    case ets:lookup(Storage, IOA) of
      [Update] -> [Update | HistoryUpdates];
      _NoUpdate -> HistoryUpdates
    end,
  [PointerUpdates | get_pointer_updates(NextOrder, NextPointer, State)];
get_pointer_updates(_NextKey, _NextPointer, _State) ->
  [].

next_queue(#state{
  pointer = ?END_OF_TABLE,
  update_queue_ets = UpdateQueue
}) ->
  case ets:first(UpdateQueue) of
    #order{pointer = Pointer} ->
      Pointer;
    _Other ->
      ?END_OF_TABLE
  end;
next_queue(#state{
  pointer = #pointer{} = Pointer,
  update_queue_ets = UpdateQueue
} = State) ->
  case ets:next(UpdateQueue, #order{pointer = Pointer, ioa = max_ioa}) of
    #order{pointer = NextPointer} ->
      NextPointer;
    _Other ->
      next_queue(State#state{pointer = ?END_OF_TABLE})
  end.
  
send_updates(Updates, #pointer{
  priority = Priority,
  type = Type,
  cot = COT
} = Pointer, #state{
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
  State#state{
    tickets = Tickets,
    pointer = Pointer
  }.

send_update(SendQueue, Priority, ASDU) ->
  ?LOGDEBUG("enqueue asdu: ~p",[ASDU]),
  SendQueue ! {send_confirm, self(), Priority, ASDU},
  receive {accepted, TicketRef} -> TicketRef end.

gi_check_termination(#state{
  pointer = #pointer{cot = COT},
  group = GroupID,
  send_queue_pid = SendQueuePID,
  asdu_settings = ASDUSettings
} = State) when (COT >= ?COT_GROUP_MIN andalso COT =< ?COT_GROUP_MAX) ->
  case next_queue(State) of
    #pointer{cot = COT} ->
      State;
    _Other ->
      Termination = gi_build_termination(GroupID, ASDUSettings),
      SendQueuePID ! {send_no_confirm, self(), ?COMMAND_PRIORITY, Termination},
      State#state{group = undefined}
  end;
gi_check_termination(State) ->
  State.

gi_get_updates(GroupID, Storage) ->
  case GroupID of
    ?GLOBAL_GROUP ->
      ets:tab2list(Storage);
    Group when Group >= ?START_GROUP andalso Group =< ?END_GROUP ->
      ets:match_object(Storage, {'_', #{group => GroupID}});
    _ ->
      []
  end.

gi_build_termination(GroupID, ASDUSettings) ->
  iec60870_server_stm:build_asdu(?C_IC_NA_1, ?COT_ACTTERM, ?POSITIVE_PN, [{0, GroupID}], ASDUSettings).