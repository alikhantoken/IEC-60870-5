%%% +--------------------------------------------------------------+
%%% | Copyright (c) 2025. All Rights Reserved.                     |
%%% | License can be found in the LICENSE file.                    |
%%% | Author: Tokenov Alikhan, alikhantokenov@gmail.com            |
%%% +--------------------------------------------------------------+

-module(iec60870).

%%% +--------------------------------------------------------------+
%%% |                            API                               |
%%% +--------------------------------------------------------------+

%% Application-level
-export([
  start_server/1,
  start_client/1,
  stop/1
]).

%% Operations
-export([
  subscribe/2, subscribe/3,
  unsubscribe/2, unsubscribe/3,
  read/1, read/2,
  write/3
]).

%% Utilities
-export([
  get_pid/1,
  diagnostics/1
]).

start_server(ConnectionSettings) ->
  iec60870_server:start(ConnectionSettings).

start_client(ConnectionSettings) ->
  iec60870_client:start(ConnectionSettings).

stop(ClientOrServer) ->
  Module = element(1, ClientOrServer),
  Module:stop(ClientOrServer).

subscribe(ClientOrServer, SubscriberPID) ->
  Module = element(1, ClientOrServer),
  Module:subscribe(ClientOrServer, SubscriberPID).

subscribe(ClientOrServer, SubscriberPID, Address) ->
  Module = element(1, ClientOrServer),
  Module:subscribe(ClientOrServer, SubscriberPID, Address).

unsubscribe(ClientOrServer, SubscriberPID, Address) ->
  Module = element(1, ClientOrServer),
  Module:unsubscribe(ClientOrServer, SubscriberPID, Address).

unsubscribe(ClientOrServer, SubscriberPID) ->
  Module = element(1, ClientOrServer),
  Module:remove_subscriber(ClientOrServer, SubscriberPID).

write(ClientOrServer, IOA, Value) ->
  Module = element(1, ClientOrServer),
  Module:write(ClientOrServer, IOA, Value).

read(ClientOrServer) ->
  Module = element(1, ClientOrServer),
  Module:read(ClientOrServer).

read(ClientOrServer, Address) ->
  Module = element(1, ClientOrServer),
  Module:read(ClientOrServer, Address).

get_pid(ClientOrServer)->
  Module = element(1, ClientOrServer),
  Module:get_pid(ClientOrServer).
  
diagnostics(ClientOrServer)->
  Module = element(1, ClientOrServer),
  Module:diagnostics(ClientOrServer).
