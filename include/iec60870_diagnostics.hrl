%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-ifndef(iec60870_diagnostics).
-define(iec60870_diagnostics, 1).

%% Must be JSON friendly Key & Value
-define(DIAGNOSTICS(Tab, Key, Value),
  ets:insert(Tab, {Key, maps:merge(Value, #{<<"timestamp">> => erlang:system_time(millisecond)})})
).

-endif.