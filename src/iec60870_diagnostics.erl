%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2025. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-module(iec60870_diagnostics).

%%% +---------------------------------------------------------------+
%%% |                              API                              |
%%% +---------------------------------------------------------------+

-export([
  add/3,
  remove/2
]).

%%% +--------------------------------------------------------------+
%%% |                         Implementation                       |
%%% +--------------------------------------------------------------+

add(Tab, Key, Value) when is_map(Value) ->
  try
    Data =
      maps:merge(
        Value,
        #{<<"timestamp">> => erlang:system_time(millisecond)}
      ),
    ets:insert(Tab, {Key, Data}),
    ok
  catch
    _Class:_Error ->
      ok
  end;
add(Tab, Key, Value) ->
  try
    ets:insert(Tab, {Key, Value}),
    ok
  catch
    _Class:_Error ->
      ok
  end.

remove(Tab, Key) ->
  try
    ets:delete(Tab, Key)
  catch
    _Class:_Error ->
      ok
  end.