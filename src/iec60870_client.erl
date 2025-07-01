%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-module(iec60870_client).

-include("iec60870.hrl").
-include("iec60870_asdu.hrl").

%%% +--------------------------------------------------------------+
%%% |                       Macros & Records                       |
%%% +--------------------------------------------------------------+

-define(REQUIRED, {?MODULE, required}).

-define(GROUP_REQUEST_ATTEMPTS, 1).
-define(GROUP_REQUEST_TIMEOUT, 60000).

-define(DEFAULT_SETTINGS, maps:merge(#{
  name => ?REQUIRED,
  type => ?REQUIRED,
  connection => ?REQUIRED,
  redundant_connection => undefined,
  groups => []
}, ?DEFAULT_ASDU_SETTINGS)).

-record(?MODULE, {
  storage,
  pid,
  name
}).

%%% +--------------------------------------------------------------+
%%% |                          Client API                          |
%%% +--------------------------------------------------------------+

-export([
  start/1,
  stop/1,
  write/3,
  read/1, read/2,
  subscribe/3, subscribe/2,
  unsubscribe/3, unsubscribe/2,
  get_pid/1
]).

%%% +---------------------------------------------------------------+
%%% |                        Cross Module API                       |
%%% +---------------------------------------------------------------+

-export([
  find_group_items/2
]).

%%% +---------------------------------------------------------------+
%%% |                   Client API Implementation                   |
%%% +---------------------------------------------------------------+

start(InSettings) ->
  #{name := Name} = Settings = check_settings(InSettings),
  PID =
    case gen_statem:start_link(iec60870_client_stm, {_OwnerPID = self(), Settings}, []) of
      {ok, _PID} -> _PID;
      {error, Error} -> throw(Error)
    end,
  receive
    {ready, PID, Storage} ->
      #?MODULE{
        pid = PID,
        name = Name,
        storage = Storage
      };
    {'EXIT', PID, Reason} ->
      ?LOGERROR("startup failed, reason: ~p", [Reason]),
      throw(Reason)
  end.

stop(#?MODULE{pid = PID}) ->
  case is_process_alive(PID) of
    true -> gen_statem:stop(PID);
    false -> ok
  end;
stop(_) ->
  throw(bad_arg).

read(Reference) ->
  find_group_items(Reference, 0).
read(#?MODULE{storage = Storage}, ID) ->
  case ets:lookup(Storage, ID) of
    [] -> undefined;
    [{ID, Value}] -> Value
  end;
read(_, _) ->
  throw(bad_arg).

write(#?MODULE{pid = PID}, IOA, InDataObject) when is_map(InDataObject) ->
  case is_process_alive(PID) of
    true ->
      case is_remote_command(InDataObject) of
        true ->
          OutDataObject = iec60870_lib:check_value(InDataObject),
          case gen_statem:call(PID, {write, IOA, OutDataObject}) of
            ok ->
              ok;
            {error, Error} ->
              ?LOGERROR("write operation failed, error: ~p", [Error]),
              throw(Error)
          end;
        false ->
          PID ! {write, IOA, InDataObject},
          ok
      end;
    false ->
      ?LOGERROR("write operation attempted on a closed connection"),
      throw(client_connection_unavailable)
  end;
write(_, _, _) ->
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

unsubscribe(Reference, PID) when is_pid(PID) ->
  AddressList = [Address || {Address, _} <- read(Reference)],
  unsubscribe(Reference, AddressList);
unsubscribe(_, _) ->
  throw(bad_arg).

get_pid(#?MODULE{pid = PID}) ->
  PID;
get_pid(_) ->
  throw(bad_arg).

%% +---------------------------------------------------------------+
%% |               Cross Module API Implementation                 |
%% +---------------------------------------------------------------+

find_group_items(#?MODULE{storage = Storage}, _GroupID = 0) ->
  ets:tab2list(Storage);

find_group_items(#?MODULE{storage = Storage}, GroupID) ->
  ets:match_object(Storage, {'_', #{group => GroupID}}).

%%% +--------------------------------------------------------------+
%%% |                      Internal functions                      |
%%% +--------------------------------------------------------------+

check_settings(Settings) when is_map(Settings) ->
  SettingsList = maps:to_list(Settings),
  case [S || {S, ?REQUIRED} <- SettingsList] of
    [] -> ok;
    Required -> throw( {required, Required} )
  end,
  case maps:keys(Settings) -- maps:keys(?DEFAULT_SETTINGS) of
    [] -> ok;
    InvalidParams -> throw({invalid_params, InvalidParams})
  end,
  OwnSettings = maps:without(maps:keys(?DEFAULT_ASDU_SETTINGS), Settings),
  maps:merge(
    maps:map(fun check_setting/2, OwnSettings),
    maps:with(maps:keys(?DEFAULT_ASDU_SETTINGS), Settings)
  );

check_settings(_) ->
  throw(invalid_settings).

check_setting(name, ConnectionName)
  when is_atom(ConnectionName) -> ConnectionName;

check_setting(type, Type)
  when Type =:= '101'; Type =:= '104' -> Type;

check_setting(connection, Settings)
  when is_map(Settings) -> Settings;

check_setting(redundant_connection, Settings)
  when is_map(Settings) orelse Settings =:= undefined -> Settings;

check_setting(groups, Groups) when is_list(Groups) ->
  [case Group of
     #{id := _ID} ->
       maps:merge(#{
         timeout => ?GROUP_REQUEST_TIMEOUT,
         attempts => ?GROUP_REQUEST_ATTEMPTS,
         required => false,
         count => undefined,
         update => undefined
       }, Group);
     Group when is_integer(Group) ->
       #{
         id => Group,
         timeout => ?GROUP_REQUEST_TIMEOUT,
         attempts => ?GROUP_REQUEST_ATTEMPTS,
         required => false,
         count => undefined,
         update => undefined
       };
     _ ->
       throw({bad_group_settings, Group})
   end || Group <- lists:uniq(Groups)];
check_setting(groups, undefined) ->
  [];
check_setting(Key, _) ->
  throw({invalid_settings, Key}).

is_remote_command(#{type := Type})->
  (Type >= ?C_SC_NA_1 andalso Type =< ?C_BO_NA_1) orelse
    (Type >= ?C_SC_TA_1 andalso Type =< ?C_BO_TA_1).