%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-ifndef(function_codes).
-define(function_codes, 1).

%% Function codes from PRIMARY to SECONDARY
-define(RESET_REMOTE_LINK, 0).
-define(RESET_USER_PROCESS, 1).
-define(LINK_TEST, 2).
-define(USER_DATA_CONFIRM, 3).
-define(USER_DATA_NO_REPLY, 4).
-define(ACCESS_DEMAND, 8).
-define(REQUEST_STATUS_LINK, 9).
-define(REQUEST_DATA_CLASS_1, 10).
-define(REQUEST_DATA_CLASS_2, 11).

%% Function codes from SECONDARY to PRIMARY
-define(ACKNOWLEDGE, 0).
-define(NACK_LINK_BUSY, 1).
-define(USER_DATA, 8).
-define(NACK_DATA_NOT_AVAILABLE, 9).
-define(STATUS_LINK_ACCESS_DEMAND, 11).
-define(ERR_NOT_FUNCTIONING, 14).
-define(ERR_NOT_IMPLEMENTED, 15).

-endif.