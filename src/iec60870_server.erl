%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License that can be found in the LICENSE file.                 |
%%% +----------------------------------------------------------------+

-module(iec60870_server).

-include("iec60870.hrl").
-include("iec60870_asdu.hrl").

%%% +--------------------------------------------------------------+
%%% |                              API                             |
%%% +--------------------------------------------------------------+

-export([
  start/1,
  stop/1,
  read/1, read/2,
  write/3,
  subscribe/3, subscribe/2,
  unsubscribe/3, unsubscribe/2,
  get_pid/1,
  diagnostics/1
]).

%%% +--------------------------------------------------------------+
%%% |                        Cross module API                      |
%%% +--------------------------------------------------------------+

-export([
  start_connection/3,
  find_group_items/2,
  update_value/3
]).

%%% +--------------------------------------------------------------+
%%% |                       Macros & Records                       |
%%% +--------------------------------------------------------------+

-record(?MODULE, {
  storage,
  pid,
  name,
  diagnostics
}).

-record(state,{
  server,
  type,
  name,
  module,
  esubscribe,
  settings,
  diagnostics
}).

-define(COMMAND_HANDLER_ARITY, 4).
-define(REQUIRED, {?MODULE, required}).

-define(DEFAULT_SETTINGS, maps:merge(#{
  name => ?REQUIRED,
  type => ?REQUIRED,
  connection => ?REQUIRED,
  groups => [],
  command_handler => undefined,
  io_updates_enabled => false
}, ?DEFAULT_ASDU_SETTINGS)).

%% +--------------------------------------------------------------+
%% |                      API implementation                      |
%% +--------------------------------------------------------------+

start(InSettings) ->
  Settings = check_settings(maps:merge(?DEFAULT_SETTINGS, InSettings)),
  Self = self(),
  PID = spawn_link(fun() -> init_server(Self, Settings) end),
  receive
    {ready, PID, ServerRef} ->
      ServerRef;
    {'EXIT', PID, Reason} ->
      ?LOGERROR("startup failed, reason: ~p", [Reason]),
      throw(Reason)
  end.

stop(#?MODULE{pid = PID}) ->
  exit(PID, shutdown);
stop(_) ->
  throw(bad_arg).

write(Reference, ID, Value) ->
  update_value(Reference, ID, Value).

read(#?MODULE{} = Ref) ->
  find_group_items(Ref, 0);
read(_) ->
  throw(bad_arg).

read(#?MODULE{storage = Storage}, ID) ->
  case ets:lookup(Storage, ID) of
    [] -> undefined;
    [{ID, Value}] -> Value
  end;
read(_, _) ->
  throw(bad_arg).

subscribe(#?MODULE{name = Name}, PID) when is_pid(PID) ->
  esubscribe:subscribe(Name, update, PID);
subscribe(_, _) ->
  throw(bad_arg).

subscribe(#?MODULE{name = Name}, PID, AddressList) when is_pid(PID), is_list(AddressList) ->
  [begin
     esubscribe:subscribe(Name, Address, PID)
   end || Address <- AddressList],
  ok;
subscribe(#?MODULE{name = Name}, PID, Address) when is_pid(PID) ->
  esubscribe:subscribe(Name, Address, PID);
subscribe(_, _, _) ->
  throw(bad_arg).

unsubscribe(#?MODULE{name = Name}, PID, AddressList) when is_list(AddressList), is_pid(PID) ->
  [begin
     esubscribe:unsubscribe(Name, Address, PID)
   end || Address <- AddressList],
  ok;
unsubscribe(#?MODULE{name = Name}, PID, Address) when is_pid(PID) ->
  esubscribe:unsubscribe(Name, Address, PID);
unsubscribe(_, _, _) ->
  throw(bad_arg).

unsubscribe(Ref, PID) when is_pid(PID) ->
  AddressList = [Address || {Address, _} <- read(Ref)],
  unsubscribe(Ref, AddressList);
unsubscribe(_, _) ->
  throw(bad_arg).

get_pid(#?MODULE{pid = PID}) ->
  PID;
get_pid(_) ->
  throw(bad_arg).
  
diagnostics(#?MODULE{diagnostics = Diagnostics}) ->
  ets:tab2list(Diagnostics).

%%% +--------------------------------------------------------------+
%%% |                Cross Module API Implementation               |
%%% +--------------------------------------------------------------+

find_group_items(#?MODULE{storage = Storage}, _GroupID = 0) ->
  ets:tab2list(Storage);

find_group_items(#?MODULE{storage = Storage}, GroupID) ->
  ets:match_object(Storage, {'_', #{group => GroupID}}).

start_connection(Root, Server, Connection) ->
  MonitorRef = erlang:monitor(process, Root),
  try
    Root ! {start_connection, Server, self(), Connection},
    receive
      {Root, PID} when is_pid(PID) ->
        {ok, PID};
      {Root, error} ->
        error;
      {'DOWN', MonitorRef, process, Root, Reason} ->
        ?LOGWARNING("failed to start server connection, root process is down: ~p", [Reason]),
        error
    end
  after
    erlang:demonitor(MonitorRef)
  end.

update_value(#?MODULE{name = Name, storage = Storage}, ID, NewObject) ->
  OldObject =
    case ets:lookup(Storage, ID) of
      [{_, Map}] -> Map;
      _ -> #{}
    end,
  MergedObject = iec60870_lib:merge_objects(OldObject, NewObject),
  ets:insert(Storage, {ID, MergedObject}),
  esubscribe:notify(Name, update, {ID, MergedObject}),
  esubscribe:notify(Name, ID, MergedObject).

%% +--------------------------------------------------------------+
%% |                       Internal functions                     |
%% +--------------------------------------------------------------+

init_server(Owner, #{
  name := Name,
  type := Type,
  connection := Connection,
  command_handler := Handler,
  io_updates_enabled := IOUpdatesEnabled
} = Settings) ->
  Module = iec60870_lib:get_driver_module(Type),
  Server =
    try
      Module:start_server(Connection)
    catch
      _Exception:Reason -> exit(Reason)
    end,
  Storage = ets:new(data_objects, [
    set,
    public,
    {read_concurrency, true},
    {write_concurrency, auto}
  ]),
  Diagnostics = ets:new(diagnostics, [
    set,
    public,
    {read_concurrency, true}
  ]),
  EsubscribePID =
    case esubscribe:start_link(Name) of
      {ok, PID} -> PID;
      {error, EsubscribeReason} -> exit(EsubscribeReason)
    end,
  Ref = #?MODULE{
    pid = self(),
    storage = Storage,
    name = Name,
    diagnostics = Diagnostics
  },
  ConnectionSettings = #{
    name => Name,
    storage => Storage,
    root => Ref,
    groups => maps:get(groups, Settings),
    command_handler => Handler,
    io_updates_enabled => IOUpdatesEnabled,
    asdu => iec60870_asdu:get_settings(maps:with(maps:keys(?DEFAULT_ASDU_SETTINGS), Settings))
  },
  Owner ! {ready, self(), Ref},
  process_flag(trap_exit, true),
  ?LOGINFO("starting ~p of type ~p", [Name, Type]),
  await_connection(#state{
    module = Module,
    server = Server,
    type = Type,
    name = Name,
    esubscribe = EsubscribePID,
    settings = ConnectionSettings,
    diagnostics = Diagnostics
  }).

await_connection(#state{
  module = Module,
  server = Server,
  type = Type,
  name = Name,
  settings = Settings,
  diagnostics = Diagnostics
} = State) ->
  receive
    {start_connection, Server, From, Connection} ->
      case iec60870_server_stm:start_link(Connection, Diagnostics, Settings) of
        {ok, PID} ->
          From ! {self(), PID};
        {error, Error} ->
          ?LOGERROR("~p of type ~p failed to start process for incoming connection, error: ~p", [Name, Type, Error]),
          From ! {self(), error}
      end,
      await_connection(State);
    {'EXIT', _PID, Reason} ->
      ?LOGERROR("~p of type ~p terminating w/ reason: ~p", [Name, Type, Reason]),
      catch Module:stop_server(Server),
      exit(Reason);
    Unexpected ->
      ?LOGWARNING("~p of type ~p received unexpected message: ~p", [Name, Type, Unexpected]),
      await_connection(State)
  end.

check_settings(Settings)->
  SettingsList = maps:to_list(Settings),
  case [S || {S, ?REQUIRED} <- SettingsList] of
    [] -> ok;
    Required -> throw({required, Required})
  end,
  case maps:keys(Settings) -- maps:keys(?DEFAULT_SETTINGS) of
    [] -> ok;
    InvalidParams -> throw({invalid_params, InvalidParams})
  end,
  OwnSettings = maps:without(maps:keys(?DEFAULT_ASDU_SETTINGS), Settings),
  maps:merge(
    maps:map(fun check_setting/2, OwnSettings),
    maps:with(maps:keys(?DEFAULT_ASDU_SETTINGS), Settings)
  ).

check_setting(name, ConnectionName)
  when is_atom(ConnectionName) -> ConnectionName;

check_setting(command_handler, undefined) ->
  undefined;
check_setting(command_handler, HandlerFunction)
  when is_function(HandlerFunction, ?COMMAND_HANDLER_ARITY) -> HandlerFunction;

check_setting(io_updates_enabled, IOUpdatesEnabled)
  when is_boolean(IOUpdatesEnabled) -> IOUpdatesEnabled;

check_setting(type, Type)
  when Type =:= '101'; Type =:= '104' -> Type;

check_setting(connection, Settings)
  when is_map(Settings) -> Settings;

check_setting(groups, Groups) when is_list(Groups) ->
  [case Group of
     #{id := _ID} ->
       Group;
     Group when is_integer(Group) ->
       #{
         id => Group,
         update => undefined
       };
     _ ->
       throw({bad_group_settings, Group})
   end || Group <- lists:uniq(Groups)];
check_setting(groups, undefined) ->
  [];

check_setting(Key, _) ->
  throw({invalid_settings, Key}).