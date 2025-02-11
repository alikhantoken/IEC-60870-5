%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-module(iec60870_client_stm).
-behaviour(gen_statem).

-include("iec60870.hrl").
-include("asdu.hrl").

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

%% The state of the state machine
-record(data, {
  type,
  esubscribe,
  owner,
  name,
  storage,
  groups,
  connections,
  connection,
  current_connection,
  asdu,
  state_acc
}).

%% To save the state of the connections (main or redundant)
-record(connecting, {
  next_state,
  failed,
  error
}).

%% To save the state of the general interrogation requests
-record(gi, {
  state,
  id,
  timeout,
  update,
  count,
  required,
  attempts,
  rest
}).

%% To save the state of the remote control requests
-record(rc, {
  state,
  type,
  from,
  ioa,
  value
}).

%% Initial state of the general interrogation
-define(GI_STATE(G), #gi{
  state = confirm,
  id = maps:get(id, G),
  timeout = maps:get(timeout, G, ?GI_DEFAULT_TIMEOUT),
  update = maps:get(update, G, undefined),
  attempts = maps:get(attempts, G, ?GI_DEFAULT_ATTEMPTS),
  count = maps:get(count, G, undefined),
  required = maps:get(required, G, false),
  rest = []
}).

%% Group request defaults
-define(GI_DEFAULT_TIMEOUT, 60000).
-define(GI_DEFAULT_ATTEMPTS, 1).

%% All states of the STM
-define(CONNECTING, connecting).
-define(CONNECTED, connected).
-define(GI_INITIALIZATION, gi_initialization).

%% Timeout for confirmations to requests
-define(CONFIRM_TIMEOUT, 10000).

%% Remote control timeout
-define(RC_TIMEOUT, 10000).

%%% +--------------------------------------------------------------+
%%% |                  OTP behaviour implementation                |
%%% +--------------------------------------------------------------+

callback_mode() -> [
  handle_event_function,
  state_enter
].

init({Owner, #{
  name := Name,
  type := Type,
  connection := ConnectionSettings,
  groups := Groups
} = Settings}) ->
  process_flag(trap_exit, true),
  Connections =
    case Settings of
      #{redundant_connection := RedundantSettings} when is_map(RedundantSettings) ->
        #{main => ConnectionSettings, redundant => RedundantSettings};
      _Other ->
        #{main => ConnectionSettings}
    end,
  Storage = ets:new(data_objects, [
    set,
    public,
    {read_concurrency, true},
    {write_concurrency, auto}
  ]),
  ASDU =
    iec60870_asdu:get_settings(maps:with(maps:keys(?DEFAULT_ASDU_SETTINGS), Settings)),
  EsubscribePID =
    case esubscribe:start_link(Name) of
      {ok, PID} -> PID;
      {error, Reason} -> exit(Reason)
    end,
  {ok, #connecting{next_state = ?GI_INITIALIZATION, failed = []}, #data{
    type = Type,
    current_connection = main,
    connections = Connections,
    esubscribe = EsubscribePID,
    owner = Owner,
    name = Name,
    storage = Storage,
    asdu = ASDU,
    groups = Groups
  }}.

%%% +--------------------------------------------------------------+
%%% |           Handling connection failure                        |
%%% +--------------------------------------------------------------+
handle_event(
  info,
  {'EXIT', Connection, Reason},
  CurrentState,
  #data{name = Name, connection = Connection, current_connection = CurrentConnection} = Data
) ->
  ?LOGERROR("client ~p connection ~p: received EXIT from connection, reason: ~p", [
    Name, CurrentConnection, Reason
  ]),

  ?LOGINFO("client ~p connection ~p try to recover connection",[Name, CurrentConnection]),

  {next_state, #connecting{next_state = CurrentState, error = Reason, failed = []}, Data};

%%% +--------------------------------------------------------------+
%%% |           Handling incoming ASDU packets                     |
%%% +--------------------------------------------------------------+

handle_event(
  info,
  {asdu, Connection, ASDU},
  _State,
  #data{name = Name, connection = Connection, asdu = ASDUSettings, current_connection = CurrentConnection} = Data
) ->
  try
    ParsedASDU = iec60870_asdu:parse(ASDU, ASDUSettings),
    {keep_state_and_data, [{next_event, internal, ParsedASDU}]}
  catch
    _:{invalid_object, _Value} = Error ->
      {stop, Error, Data};
    _:Error ->
      ?LOGERROR("client ~p connection ~p: invalid ASDU received: ~p, error: ~p", [Name, CurrentConnection, ASDU, Error]),
      keep_state_and_data
  end;

%%% +--------------------------------------------------------------+
%%% |                      Connecting State                        |
%%% +--------------------------------------------------------------+

handle_event(
  enter,
  _PrevState,
  #connecting{},
  #data{name = Name, current_connection = CurrentConnection} = _Data
) ->
  ?LOGDEBUG("client ~p connection ~p: entering CONNECTING state", [Name, CurrentConnection]),
  {keep_state_and_data, [{state_timeout, 0, connect}]};

handle_event(
  state_timeout,
  connect,
  #connecting{failed = Failed, error = Error},
  #data{connections = Connections, name = Name} = Data
) when length(Failed) =:= map_size(Connections) ->
  ?LOGERROR("client ~p failed to start all connections w/ reason: ~p", [Name, Error]),
  {stop, Error, Data};

handle_event(
  state_timeout,
  connect,
  #connecting{failed = Failed, next_state = NextState} = Connecting,
  #data{current_connection = CurrentConnection, type = Type, connections = Connections, name = Name} = Data
) ->
  Module = iec60870_lib:get_driver_module(Type),
  try
    Connection = Module:start_client(maps:get(CurrentConnection, Connections)),
    ?LOGINFO("client ~p started ~p connection", [Name, CurrentConnection]),
    {next_state, NextState, Data#data{connection = Connection}}
  catch
    _Exception:Reason ->
      ?LOGWARNING("client ~p failed to start ~p connection w/ reason: ~p", [Name, CurrentConnection, Reason]),
      {next_state, Connecting#connecting{
        failed = [CurrentConnection | Failed],
        error = Reason
      }, Data#data{
        current_connection = switch_connection(CurrentConnection)
      }}
  end;

%%% +--------------------------------------------------------------+
%%% |                      Init Groups State                       |
%%% +--------------------------------------------------------------+

handle_event(
  enter,
  _PrevState,
  ?GI_INITIALIZATION,
  #data{name = Name, current_connection = CurrentConnection} = _Data
) ->
  ?LOGDEBUG("client ~p connection ~p: entering INIT GROUPS state", [Name, CurrentConnection]),
  {keep_state_and_data, [{state_timeout, 0, init}]};

handle_event(
  state_timeout,
  init,
  ?GI_INITIALIZATION,
  #data{owner = Owner, storage = Storage, groups = Groups} = Data
) ->
  GIs = [?GI_STATE(G) || G <- Groups],
  % Init update events for not required groups. They are handled in the normal mode
  [self() ! GI || GI = #gi{required = false} <- GIs],
  % Get required groups
  Required = [GI || GI = #gi{required = true} <- GIs],
  case Required of
    [G | Rest] ->
      {next_state, G#gi{rest = Rest}, Data};
    _ ->
      Owner ! {ready, self(), Storage},
      {next_state, ?CONNECTED, Data}
  end;

%%% +--------------------------------------------------------------+
%%% |                        Group Interrogation                   |
%%% +--------------------------------------------------------------+

%% Sending group request and starting timer for confirmation
handle_event(
  enter,
  _PrevState,
  #gi{state = confirm, id = ID},
  #data{name = Name, asdu = ASDUSettings, connection = Connection, current_connection = CurrentConnection}
) ->
  ?LOGDEBUG("client ~p connection ~p: sending GI REQUEST for group ~p", [Name, CurrentConnection, ID]),
  [GroupRequest] = iec60870_asdu:build(#asdu{
    type = ?C_IC_NA_1,
    pn = ?POSITIVE_PN,
    cot = ?COT_ACT,
    objects = [{_IOA = 0, ID}]
  }, ASDUSettings),
  send_asdu(Connection, GroupRequest),
  {keep_state_and_data, [{state_timeout, ?CONFIRM_TIMEOUT, timeout}]};

%% GI Confirm
handle_event(
  internal,
  #asdu{type = ?C_IC_NA_1, cot = ?COT_ACTCON, pn = ?POSITIVE_PN, objects = [{_IOA, ID}]},
  #gi{state = confirm, id = ID} = State,
  #data{name = Name, current_connection = CurrentConnection} = Data
) ->
  ?LOGDEBUG("client ~p connection ~p: GI CONFIRMATION for group ~p", [Name, CurrentConnection, ID]),
  {next_state, State#gi{state = run}, Data};

%% GI Reject
handle_event(
  internal,
  #asdu{type = ?C_IC_NA_1, cot = ?COT_ACTCON, pn = ?NEGATIVE_PN, objects = [{_IOA, ID}]},
  #gi{state = confirm, id = ID} = State,
  #data{name = Name, current_connection = CurrentConnection} = Data
) ->
  ?LOGWARNING("client ~p connection ~p: group ~p interrogation rejected", [Name, CurrentConnection, ID]),
  {next_state, State#gi{state = error}, Data};

handle_event(
  state_timeout,
  timeout,
  #gi{state = confirm, id = ID} = State,
  #data{name = Name, current_connection = CurrentConnection} = Data
) ->
  ?LOGWARNING("client ~p connection ~p: group ~p interrogation confirmation timeout", [Name, CurrentConnection, ID]),
  {next_state, State#gi{state = error}, Data};

%% GI Running
handle_event(
  enter,
  _PrevState,
  #gi{state = run, timeout = Timeout, id = ID},
  #data{name = Name, current_connection = CurrentConnection} = Data
) ->
  ?LOGDEBUG("client ~p connection ~p: GI RUN state for group ~p", [Name, CurrentConnection, ID]),
  {keep_state, Data#data{state_acc = #{}}, [{state_timeout, Timeout, timeout}]};

%% Update received
handle_event(
  internal,
  #asdu{type = Type, objects = Objects, cot = COT} = ASDU,
  #gi{state = run, id = ID},
  #data{name = Name, storage = Storage, state_acc = GroupItems0, current_connection = CurrentConnection} = Data
) when (COT - ?COT_GROUP_MIN) =:= ID ->
  ?LOGDEBUG("client ~p connection ~p: GI UPDATE for group: ~p, ASDU: ~p", [Name, CurrentConnection, ID, ASDU]),
  GroupItems =
    lists:foldl(
      fun({IOA, Value}, AccIn) ->
        update_value(Name, Storage, IOA, Value#{type => Type, group => ID}),
        AccIn#{IOA => Value}
      end, GroupItems0, Objects),
  {keep_state, Data#data{state_acc = GroupItems}};

%% GI Termination (Completed)
handle_event(
  internal,
  #asdu{type = ?C_IC_NA_1, cot = ?COT_ACTTERM, pn = ?POSITIVE_PN, objects = [{_IOA, ID}]},
  #gi{state = run, id = ID, count = Count} = State,
  #data{name = Name, state_acc = GroupItems, current_connection = CurrentConnection} = Data
) ->
  ?LOGDEBUG("client ~p connection ~p: GI TERMINATION for group ~p", [Name, CurrentConnection, ID]),
  IsSuccessful =
    if
      is_number(Count) -> map_size(GroupItems) >= Count;
      true -> true
    end,
  if
    IsSuccessful ->
      {next_state, State#gi{state = finish}, Data};
    true ->
      {next_state, State#gi{state = error}, Data}
  end;

%% Interrupted
handle_event(
  internal,
  #asdu{type = ?C_IC_NA_1, cot = ?COT_ACTTERM, pn = ?NEGATIVE_PN, objects = [{_IOA, ID}]},
  #gi{state = run, id = ID} = State,
  Data
) ->
  {next_state, State#gi{state = error}, Data};

handle_event(
  state_timeout,
  timeout,
  #gi{state = run, count = Count} = State,
  #data{state_acc = GroupItems} = Data
) ->
  IsSuccessful = is_number(Count) andalso (map_size(GroupItems) >= Count),
  if
    IsSuccessful ->
      {next_state, State#gi{state = finish}, Data};
    true ->
      {next_state, State#gi{state = error}, Data}
  end;

%% GI Error (Timeout)
handle_event(
  enter,
  _PrevState,
  #gi{state = error, id = ID},
  #data{name = Name, current_connection = CurrentConnection} = _Data
) ->
  ?LOGDEBUG("client ~p connection ~p: GI TIMEOUT for group ~p", [Name, CurrentConnection, ID]),
  {keep_state_and_data, [{state_timeout, 0, timeout}]};

handle_event(
  state_timeout,
  timeout,
  #gi{state = error, id = ID, required = Required, attempts = Attempts} = State,
  #data{name = Name, current_connection = CurrentConnection} = Data
) ->
  RestAttempts = Attempts - 1,
  ?LOGDEBUG("client ~p connection ~p: GI attempts left ~p for group ~p", [Name, CurrentConnection, RestAttempts, ID]),
  if
    RestAttempts > 0 ->
      {next_state, State#gi{state = confirm, attempts = RestAttempts}, Data};
    Required =:= true ->
      {stop, {group_interrogation_error, ID}};
    true ->
      {next_state, State#gi{state = finish}, Data}
  end;

%% GI finish
handle_event(
  enter,
  _PrevState,
  #gi{state = finish, id = ID},
  #data{name = Name, current_connection = CurrentConnection}
) ->
  ?LOGDEBUG("client ~p connection ~p: GI FINISH for group ~p", [Name, CurrentConnection, ID]),
  {keep_state_and_data, [{state_timeout, 0, timeout}]};

handle_event(
  state_timeout,
  timeout,
  #gi{state = finish, update = Update, rest = RestGI, required = IsRequired} = State,
  #data{owner = Owner, storage = Storage} = Data
) ->
  case {IsRequired, RestGI} of
    {true, []} ->
      Owner ! {ready, self(), Storage};
    _ ->
      ignore
  end,
  % If the group must be cyclically updated queue the event
  if
    is_integer(Update) ->
      timer:send_after(Update, State#gi{state = confirm, required = false, rest = []});
    true ->
      ignore
  end,
  case RestGI of
    [NextGI | Rest] ->
      {next_state, NextGI#gi{rest = Rest}, Data};
    _ ->
      {next_state, ?CONNECTED, Data#data{state_acc = undefined}}
  end;

%%% +--------------------------------------------------------------+
%%% |                          Connected                           |
%%% +--------------------------------------------------------------+

handle_event(
  enter,
  _PrevState,
  ?CONNECTED,
  #data{name = Name, current_connection = CurrentConnection} = _Data
) ->
  ?LOGDEBUG("client ~p connection ~p: entering CONNECTED state", [Name, CurrentConnection]),
  keep_state_and_data;

handle_event(
  info,
  {write, IOA, Value},
  ?CONNECTED,
  #data{name = Name, connection = Connection, asdu = ASDUSettings, storage = Storage}
) ->
  % Getting all updates
  NextItems = [Object || {Object, _Node, A} <- esubscribe:lookup(Name, update), A =/= self()],
  MergedObject = {IOA, merge_existing_io(IOA, Value, Storage)},
  send_items([MergedObject | NextItems], Connection, ?COT_SPONT, ASDUSettings),
  keep_state_and_data;

%% Handling call of remote control command
handle_event(
  {call, From},
  {write, IOA, Value},
  ?CONNECTED,
  Data
) ->
  % Start write request
  RC = #rc{
    state = confirm,
    type = maps:get(type, Value),
    from = From,
    ioa = IOA,
    value = Value
  },
  {next_state, RC, Data};

%% Event for the group update is received
%% Changing state to the group interrogation
handle_event(
  info,
  #gi{} = GI,
  ?CONNECTED,
  Data
) ->
  {next_state, GI, Data};

%%% +--------------------------------------------------------------+
%%% |                Sending remote control command                |
%%% +--------------------------------------------------------------+

%% Sending remote control command
handle_event(
  enter,
  _PrevState,
  #rc{state = confirm, type = Type, ioa = IOA, value = Value},
  #data{name = Name, connection = Connection, asdu = ASDUSettings}
) ->
  [ASDU] = iec60870_asdu:build(#asdu{
    type = Type,
    pn = ?POSITIVE_PN,
    cot = ?COT_ACT,
    objects = [{IOA, Value}]
  }, ASDUSettings),
  send_asdu(Connection, ASDU),
  ?LOGINFO("client ~p connection ~p: sent RC command activation! IOA: ~p, Type: ~p, Data object: ~p", [
    Name, Connection, IOA, Type, Value
  ]),
  {keep_state_and_data, [{state_timeout, ?CONFIRM_TIMEOUT, timeout}]};

%% Remote control command confirmation
handle_event(
  internal,
  #asdu{type = Type, cot = ?COT_ACTCON, pn = ?POSITIVE_PN, objects = [{IOA, _}]},
  #rc{state = confirm, ioa = IOA, type = Type} = State,
  #data{name = Name, current_connection = CurrentConnection} = Data
) ->
  ?LOGINFO("client ~p connection ~p: RC command confirmation! IOA: ~p, Type: ~p", [
    CurrentConnection, Name, IOA, Type
  ]),
  {next_state, State#rc{state = run}, Data};

%% Remote control command rejected
handle_event(
  internal,
  #asdu{type = Type, cot = ?COT_ACTCON, pn = ?NEGATIVE_PN, objects = [{IOA, _}]},
  #rc{state = confirm, ioa = IOA, type = Type, from = From},
  #data{name = Name, current_connection = CurrentConnection} = Data
) ->
  ?LOGWARNING("client ~p connection ~p: RC command rejected! IOA: ~p, Type: ~p", [
    Name, CurrentConnection, IOA, Type
  ]),
  {next_state, ?CONNECTED, Data, [{reply, From, {error, reject}}]};

handle_event(
  state_timeout,
  timeout,
  #rc{state = confirm, ioa = IOA, type = Type, from = From},
  #data{name = Name, current_connection = CurrentConnection} = Data
) ->
  ?LOGWARNING("client ~p connection ~p: RC command confirmation timeout! IOA: ~p, Type: ~p", [
    Name, CurrentConnection, IOA, Type
  ]),
  {next_state, ?CONNECTED, Data, [{reply, From, {error, confirm_timeout}}]};

%% Remote control command running
handle_event(
  enter,
  _PrevState,
  #rc{state = run},
  _Data
) ->
  {keep_state_and_data, [{state_timeout, ?RC_TIMEOUT, timeout}]};

%% Remote control command termination
handle_event(
  internal,
  #asdu{type = Type, cot = ?COT_ACTTERM, pn = ?POSITIVE_PN, objects = [{IOA, _}]},
  #rc{state = run, ioa = IOA, type = Type, from = From},
  #data{name = Name, current_connection = CurrentConnection} = Data
) ->
  ?LOGINFO("client ~p connection ~p: RC command positive termination! IOA: ~p, Type: ~p", [
    Name, CurrentConnection, IOA, Type
  ]),
  {next_state, ?CONNECTED, Data, [{reply, From, ok}]};

% Not executed
handle_event(
  internal,
  #asdu{type = Type, cot = ?COT_ACTTERM, pn = ?NEGATIVE_PN, objects = [{IOA, _}]},
  #rc{state = run, ioa = IOA, type = Type, from = From},
  #data{name = Name, current_connection = CurrentConnection} = Data
) ->
  ?LOGWARNING("client ~p connection ~p: RC command negative termination! IOA: ~p, Type: ~p", [
    Name, CurrentConnection, IOA, Type
  ]),
  {next_state, ?CONNECTED, Data, [{reply, From, {error, not_executed}}]};

handle_event(
  state_timeout,
  timeout,
  #rc{state = run, ioa = IOA, type = Type, from = From},
  #data{name = Name, current_connection = CurrentConnection} = Data
) ->
  ?LOGWARNING("client ~p connection ~p: RC command termination timeout! IOA: ~p, Type: ~p", [
    Name, CurrentConnection, IOA, Type
  ]),
  {next_state, ?CONNECTED, Data, [{reply, From, {error, execute_timeout}}]};

%%% +--------------------------------------------------------------+
%%% |                     Handling normal updates                  |
%%% +--------------------------------------------------------------+

handle_event(
  internal,
  #asdu{type = Type, objects = Objects, cot = COT} = ASDU,
  _AnyState,
  #data{name = Name, storage = Storage, current_connection = CurrentConnection}
) when (Type >= ?M_SP_NA_1 andalso Type =< ?M_ME_ND_1)
  orelse (Type >= ?M_SP_TB_1 andalso Type =< ?M_EP_TD_1)
  orelse (Type =:= ?M_EI_NA_1) ->
  ?LOGDEBUG("client ~p connection ~p: normal ASDU update: ~p", [Name, CurrentConnection, ASDU]),
  Group =
    if
      COT >= ?COT_GROUP_MIN, COT =< ?COT_GROUP_MAX ->
        COT - ?COT_GROUP_MIN;
      true ->
        undefined
    end,
  [begin
     update_value(Name, Storage, IOA, Value#{type => Type, group => Group})
   end || {IOA, Value} <- Objects],
  keep_state_and_data;

%%% +--------------------------------------------------------------+
%%% |                  Time synchronization request                |
%%% +--------------------------------------------------------------+

handle_event(
  internal,
  #asdu{type = ?C_CS_NA_1, objects = Objects},
  _AnyState,
  #data{asdu = ASDUSettings, connection = Connection}
) ->
  [Confirmation] = iec60870_asdu:build(#asdu{
    type = ?C_CS_NA_1,
    pn = ?POSITIVE_PN,
    cot = ?COT_SPONT,
    objects = Objects
  }, ASDUSettings),
  send_asdu(Connection, Confirmation),
  keep_state_and_data;

%%% +--------------------------------------------------------------+
%%% |                        Unexpected ASDU                       |
%%% +--------------------------------------------------------------+

handle_event(
  internal,
  #asdu{type = ?C_IC_NA_1, cot = ?COT_ACTTERM, pn = PN, objects = [{_IOA, ID}]},
  _AnyState,
  #data{name = Name, current_connection = CurrentConnection}
) ->
  ?LOGINFO("client ~p connection ~p: termination of the group interrogation by ID: ~p, PN: ~p", [
    Name,
    CurrentConnection,
    ID,
    PN
  ]),
  keep_state_and_data;

handle_event(
  internal,
  #asdu{} = Unexpected,
  State,
  #data{name = Name, current_connection = CurrentConnection}
) ->
  ?LOGWARNING("client ~p connection ~p: unexpected ASDU type: ~p, state: ~p", [
    Name,
    CurrentConnection,
    Unexpected,
    State
  ]),
  keep_state_and_data;

%%% +--------------------------------------------------------------+
%%% |                          Other events                        |
%%% +--------------------------------------------------------------+

%% Notify event from esubscribe, postpone until CONNECTED
handle_event(
  info,
  {write, _IOA, _Value},
  _State,
  _Data
) ->
  %% TODO. Can we send information packets during group interrogation?
  {keep_state_and_data, [postpone]};

handle_event(
  {call, _From},
  {write, _IOA, _Value},
  _State,
  _Data
) ->
  {keep_state_and_data, [postpone]};

% Group interrogation request, postpone until CONNECTED
handle_event(
  info,
  #gi{},
  _AnyState,
  _Data
) ->
  {keep_state_and_data, [postpone]};

%% Failed send errors received from client connection
handle_event(
  info,
  {send_error, Connection, Error},
  _AnyState,
  #data{name = Name, current_connection = CurrentConnection, connection = Connection}
) ->
  ?LOGERROR("client ~p connection ~p: failed to send packet, error: ~p", [Name, CurrentConnection, Error]),
  keep_state_and_data;

handle_event(
  info,
  {'EXIT', PID, Reason},
  _AnyState,
  #data{name = Name, current_connection = CurrentConnection}
) ->
  ?LOGERROR("client ~p connection ~p: received EXIT from PID: ~p, reason: ~p", [
    Name, CurrentConnection, PID, Reason
  ]),
  {stop, Reason};

handle_event(
  EventType,
  EventContent,
  _AnyState,
  #data{name = Name, current_connection = CurrentConnection}
) ->
  ?LOGERROR("client ~p connection ~p: received unexpected event type: ~p, content ~p", [
    Name, CurrentConnection, EventType, EventContent
  ]),
  keep_state_and_data.

terminate(Reason, _, #data{
  name = Name,
  connection = Connection,
  current_connection = CurrentConnection,
  esubscribe = Esubscribe
}) ->
  catch exit(Connection, shutdown),
  catch exit(Esubscribe, shutdown),
  ?LOGERROR("client ~p connection ~p: termination with reason: ~p", [Name, CurrentConnection, Reason]),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%% +--------------------------------------------------------------+
%%% |                       Helper functions                       |
%%% +--------------------------------------------------------------+

merge_existing_io(IOA, NewObject, Storage) ->
  case ets:lookup(Storage, IOA) of
    [{_IOA, OldObject}] ->
      maps:merge(OldObject, NewObject);
    _NonExistent ->
      maps:without([accept_ts, group], NewObject)
  end.

%% Sending data objects
send_items(Items, Connection, COT, ASDUSettings) ->
  TypedItems = group_by_types(Items),
  [begin
     ASDUList = iec60870_asdu:build(#asdu{
       type = Type,
       pn = ?POSITIVE_PN,
       cot = COT,
       objects = Objects
     }, ASDUSettings),
     [send_asdu(Connection, ASDU) || ASDU <- ASDUList]
   end || {Type, Objects} <- TypedItems].

group_by_types(Objects) ->
  group_by_types(Objects, #{}).
group_by_types([{IOA, #{type := Type} = Value} | Rest], Acc) ->
  TypeAcc = maps:get(Type, Acc, #{}),
  Acc1 = Acc#{Type => TypeAcc#{IOA => Value}},
  group_by_types(Rest, Acc1);
group_by_types([], Acc) ->
  [{Type, lists:sort(maps:to_list(Objects))} || {Type, Objects} <- maps:to_list(Acc)].

send_asdu(Connection, ASDU) ->
  Ref = make_ref(),
  Connection ! {asdu, self(), Ref, ASDU},
  receive
    {confirm, Ref} ->
      ok;
    {'EXIT', Connection, Reason} = ExitMessage ->
      ?LOGWARNING("connection ~p is down w/ reason: ~p", [Connection, Reason]),
      self() ! ExitMessage,
      ok
  end.

update_value(Name, Storage, ID, NewObject) ->
  OldObject =
    case ets:lookup(Storage, ID) of
      [{_, Map}] -> Map;
      _ -> #{}
    end,

  MergedObject = merge_objects(OldObject, NewObject),

  ets:insert(Storage, {ID, MergedObject}),
  esubscribe:notify(Name, update, {ID, MergedObject}),
  esubscribe:notify(Name, ID, MergedObject).

%% Alternating between connections
switch_connection(_Connection = main) -> redundant;
switch_connection(_Connection = redundant) -> main.

%% +--------------------------------------------------------------+
%% |                       Merge functions                        |
%% +--------------------------------------------------------------+

merge_objects(OldObject, NewObject) ->
  OldType = maps:get(type, OldObject, undefined),
  NewType = maps:get(type, NewObject, undefined),

  ResultObject = 
    case OldType of
      NewType -> maps:merge(OldObject, NewObject);
      _Differs ->
        case ?MAPPING of
          #{OldType := NewType} -> maps:merge(OldObject, NewObject#{type => OldType});
          _Other -> NewObject
        end
    end,

  Output = maps:merge(
    #{value => undefined, group => undefined},
    ResultObject#{accept_ts => erlang:system_time(millisecond)}
  ),
  check_value(Output).

%% The object data must contain a 'value' key
check_value(#{value := Value} = ObjectData) when is_number(Value) ->
  ObjectData;
%% If an object's value is undefined, then we set its value
%% to 0 and enable the quality bit for invalid values
check_value(#{value := none} = ObjectData) ->
  ObjectData#{value => 0};
check_value(#{value := undefined} = ObjectData) ->
  ObjectData#{value => 0};
%% Key 'value' is missing, incorrect object passed
check_value(_Value) ->
  throw({error, value_parameter_missing}).