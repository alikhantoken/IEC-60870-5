%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-module(iec60870_lib).

-include("iec60870.hrl").

%%% +--------------------------------------------------------------+
%%% |                           API                                |
%%% +--------------------------------------------------------------+

-export([
  bytes_to_bits/1,
  get_driver_module/1,
  merge_objects/2,
  check_value/1
]).

%%% +--------------------------------------------------------------+
%%% |                      API Implementation                      |
%%% +--------------------------------------------------------------+

get_driver_module('104') -> iec60870_104;
get_driver_module('101') -> iec60870_101;
get_driver_module(Type)  -> throw({invalid_protocol_type, Type}).

merge_objects(OldObject, NewObject) ->
  OldType = maps:get(type, OldObject, undefined),
  NewType = maps:get(type, NewObject, undefined),

  ResultObject =
    case OldType of
      NewType ->
        maps:merge(OldObject, NewObject);
      _Differs ->
        case ?COMPATIBLE_IO_MAPPING of
          #{OldType := NewType} ->
            maps:merge(OldObject, NewObject#{type => OldType});
          _Other ->
            NewObject
        end
    end,

  Output = maps:merge(
    #{value => undefined, group => undefined},
    ResultObject#{accept_ts => erlang:system_time(millisecond)}
  ),

  check_value(Output).

check_value(#{value := Value} = ObjectData) when is_number(Value) ->
  ObjectData;
check_value(#{value := none} = ObjectData) ->
  ObjectData#{value => 0};
check_value(#{value := undefined} = ObjectData) ->
  ObjectData#{value => 0};
check_value(Value) ->
  throw({error, {invalid_value_parameter, Value}}).

bytes_to_bits(Bytes) -> Bytes * 8.