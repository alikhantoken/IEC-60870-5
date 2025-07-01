%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-module(iec60870_balanced_client).

-include("iec60870.hrl").
-include("iec60870_ft12.hrl").

%%% +--------------------------------------------------------------+
%%% |                             API                              |
%%% +--------------------------------------------------------------+

-export([
  start/2,
  stop/1
]).

%%% +--------------------------------------------------------------+
%%% |                        Implementation                        |
%%% +--------------------------------------------------------------+

start(Owner, Options) ->
  PID = iec60870_balanced:start(_Direction = ?FROM_A_TO_B, Options),
  receive
    {connected, PID} ->
      PID ! {connection, self(), Owner},
      PID;
    {'EXIT', PID, Reason} ->
      throw(Reason);
    {'EXIT', Owner, Reason} ->
      exit(PID, Reason)
  end.

stop(PID) ->
  iec60870_balanced:stop(PID).