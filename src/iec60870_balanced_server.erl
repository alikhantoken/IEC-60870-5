%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-module(iec60870_balanced_server).

-include("iec60870.hrl").
-include("iec60870_ft12.hrl").

-export([
  start/2,
  stop/1
]).

%%% +--------------------------------------------------------------+
%%% |                             API                              |
%%% +--------------------------------------------------------------+

start(Root, Options) ->
  PID = spawn(fun() -> init(Root, Options) end),
  receive
    {ready, PID} -> PID;
    {'EXIT', PID, Reason} -> throw(Reason)
  end.

stop(PID) ->
  catch exit(PID, shutdown).

%%% +--------------------------------------------------------------+
%%% |                      Internal functions                      |
%%% +--------------------------------------------------------------+

init(Root, Options)->
  process_flag(trap_exit, true),
  Port = start_connection(Root, Options),
  Root ! {ready, self()},
  accept_connection(Root, Port, Options).

start_connection(Root, Options) ->
  try iec60870_balanced:start(_Direction = ?FROM_B_TO_A, Options)
  catch
    _:E ->
      exit(Root, {transport_error, E}),
      exit(E)
  end.

accept_connection(Root, Port, Options)->
  receive
    {connected, Port} ->
      case iec60870_server:start_connection(Root, {?MODULE, self()}, Port) of
        {ok, Connection} ->
          Port ! {connection, self(), Connection},
          accept_connection(Root, Port, Options);
        error ->
          unlink(Root),
          exit(Port, shutdown),
          NewPort = start_connection(Root, Options),
          accept_connection(Root, NewPort, Options)
      end;
    {'EXIT', Port, Reason} ->
      case Reason of
        connect_error ->
          ?LOGWARNING("wait connection");
        _ ->
          ?LOGWARNING("port exit reason: ~p",[Reason])
      end,
      NewPort = start_connection(Root, Options),
      accept_connection(Root, NewPort, Options);
    {'EXIT', Root, Reason} ->
      exit(Port, Reason),
      exit(Reason)
  end.