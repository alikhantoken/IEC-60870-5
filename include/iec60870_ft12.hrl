%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-ifndef(iec60870_ft12).
-define(iec60870_ft12, 1).

%% Physical transmission direction
-define(FROM_A_TO_B, 1).
-define(FROM_B_TO_A, 0).

-record(control_field_request, {
  direction,
  fcb,
  fcv,
  function_code
}).

-record(control_field_response, {
  direction,
  acd,
  dfc,
  function_code
}).

-record(frame, {
  address,
  control_field,
  data
}).

-endif.