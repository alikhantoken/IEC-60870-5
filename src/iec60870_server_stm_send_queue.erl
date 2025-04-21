%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2025. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-module(iec60870_server_stm_send_queue).
-include("iec60870.hrl").

%%% +---------------------------------------------------------------+
%%% |                              API                              |
%%% +---------------------------------------------------------------+

-export([start_link/2]).

%%% +---------------------------------------------------------------+
%%% |                         Macros & Records                      |
%%% +---------------------------------------------------------------+

-record(state, {
  owner,
  name,
  tickets,
  update_queue_pid,
  send_queue,
  connection,
  counter
}).

%%% +--------------------------------------------------------------+
%%% |                      Send Queue Process                      |
%%% +--------------------------------------------------------------+
%%% | Description: send queue process is ONLY responsible for      |
%%% | sending data from state machine process to the connection    |
%%% | process (i.e. transport level).                              |
%%% +--------------------------------------------------------------+
%%% | Send queue ETS format: {Priority, Ref} => ASDU               |
%%% +--------------------------------------------------------------+

start_link(Name, Connection) ->
  Owner = self(),
  {ok, spawn_link(
    fun() ->
      SendQueue = ets:new(send_queue, [
        ordered_set,
        private
      ]),
      ?LOGINFO("~p starting send queue...", [Name]),
      send_queue(#state{
        owner = Owner,
        name = Name,
        send_queue = SendQueue,
        connection = Connection,
        tickets = #{},
        counter = 0
      })
    end)}.

send_queue(#state{
  send_queue = SendQueue,
  name = Name,
  tickets = Tickets,
  counter = Counter
} = InState) ->
  State =
    receive
      {confirm, Reference} ->
        return_confirmation(Tickets, Reference),
        InState#state{tickets = maps:remove(Reference, Tickets)};
      {send_confirm, Sender, Priority, ASDU} ->
        Sender ! {accepted, Counter},
        ets:insert(SendQueue, {{Priority, Counter}, {Sender, ASDU}}),
        InState#state{counter = Counter + 1};
      {send_no_confirm, _Sender, Priority, ASDU} ->
        ets:insert(SendQueue, {{Priority, Counter}, {none, ASDU}}),
        InState#state{counter = Counter + 1};
      Unexpected ->
        ?LOGWARNING("~p received unexpected message: ~p", [Name, Unexpected]),
        InState
    end,
  OutState = check_send_queue(State),
  send_queue(OutState).

check_send_queue(#state{
  send_queue = SendQueue,
  connection = Connection,
  tickets = Tickets
} = InState) when map_size(Tickets) =:= 0 ->
  case ets:first(SendQueue) of
    '$end_of_table' ->
      InState;
    {_Priority, Reference} = Key ->
      % We save the ticket to wait for confirmation for this process
      [{_Key, {Sender, ASDU}}] = ets:take(SendQueue, Key),
      send_to_connection(Connection, Reference, ASDU),
      InState#state{tickets = Tickets#{Reference => Sender}}
  end;
check_send_queue(#state{} = State) ->
  State.

%%% +--------------------------------------------------------------+
%%% |                      Helper functions                        |
%%% +--------------------------------------------------------------+

return_confirmation(Tickets, Reference) ->
  case Tickets of
    #{Reference := Sender} when is_pid(Sender) ->
      Sender ! {confirm, Reference};
    _Other ->
      ok
  end.

send_to_connection(Connection, Reference, ASDU) ->
  Connection ! {asdu, self(), Reference, ASDU}.
  