%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-module(iec60870_unbalanced_client).

-include("iec60870.hrl").
-include("ft12.hrl").
-include("function_codes.hrl").

%%% +--------------------------------------------------------------+
%%% |                             API                              |
%%% +--------------------------------------------------------------+

-export([
  start/2,
  stop/1
]).

%%% +--------------------------------------------------------------+
%%% |                       Macros & Records                       |
%%% +--------------------------------------------------------------+

-define(RESPONSE(Address, FC, UserData), #frame{
  address = Address,
  control_field = #control_field_response{
    direction = 0,
    acd = 0,
    dfc = 0,
    function_code = FC
  },
  data = UserData
}).

-record(port_state, {
  name,
  port_ft12,
  clients
}).

-record(data, {
  state,
  name,
  owner,
  port,
  cycle
}).

%%% +--------------------------------------------------------------+
%%% |                       API implementation                     |
%%% +--------------------------------------------------------------+

start(Owner, Options) ->
  PID = spawn_link(fun() -> init_client(Owner, Options) end),
  receive
    {connected, PID} ->
      PID;
    {'EXIT', PID, Reason} ->
      ?LOGERROR("received EXIT, reason: ~p", [Reason]),
      throw(Reason);
    {'EXIT', Owner, Reason} ->
      ?LOGERROR("received EXIT from owner, reason: ~p", [Reason]),
      exit(PID, Reason)
  end.

stop(Port) ->
  catch exit(Port, shutdown).

%%% +--------------------------------------------------------------+
%%% |                      Internal functions                      |
%%% +--------------------------------------------------------------+

init_client(Owner, #{cycle := Cycle, transport := #{name := PortName}} = Options) ->
  Port = start_port(Options),
  State = connect(Port, Options),
  Owner ! {connected, self()},
  self() ! {update, self()},
  ?LOGINFO("~p starting, owner: ~p, cycle: ~p", [PortName, Owner, Cycle]),
  loop(#data{
    state = State,
    name = PortName,
    cycle = Cycle,
    owner = Owner,
    port = Port
  }).

connect(Port, #{transport := #{name := PortName}} = Options) ->
  Port ! {add_client, self(), Options},
  receive
    {ok, Port, ClientState} ->
      ?LOGINFO("~p successfully added self to ~p", [PortName, Port]),
      ClientState;
    {error, Port, AddClientError} ->
      ?LOGERROR("~p failed to add self to ~p, error: ~p", [PortName, Port, AddClientError]),
      exit(AddClientError)
  end.

loop(#data{
  name = Name,
  owner = Owner,
  cycle = Cycle
} = Data) ->
  receive
    {update, Self} when Self =:= self() ->
      ?LOGDEBUG("~p received self update", [Name]),
      timer:send_after(Cycle, {update, Self}),
      NewData = get_data(Data),
      loop(NewData);
    {access_demand, Self} when Self =:= self() ->
      ?LOGDEBUG("~p received self access demand", [Name]),
      NewData = get_data(Data),
      loop(NewData);
    {asdu, Owner, Reference, ASDU} ->
      Owner ! {confirm, Reference},
      NewData = send_asdu(ASDU, Data),
      loop(NewData);
    Unexpected ->
      ?LOGWARNING("~p received unexpected message: ~p", [Name, Unexpected]),
      loop(Data)
  end.

get_data(Data) ->
  drop_access_demand(),
  NewData = send_data_class_request(?REQUEST_DATA_CLASS_1, Data),
  send_data_class_request(?REQUEST_DATA_CLASS_2, NewData).

drop_access_demand() ->
  receive
    {access_demand, _AnyPID} ->
      drop_access_demand()
  after
    0 -> ok
  end.

send_data_class_request(DataClass, #data{
  state = State,
  port = Port,
  owner = Owner
} = Data) ->
  DataClassRequest = fun() -> iec60870_101:data_class(DataClass, State) end,
  case send_request(Port, DataClassRequest) of
    error ->
      ?LOGERROR("~p failed to request [DATA CLASS ~p]", [Port, DataClass]),
      exit({data_class_request_failure, DataClass});
    {NewState, ACD, ASDU} ->
      send_asdu_to_owner(Owner, ASDU),
      check_access_demand(ACD),
      Data#data{state = NewState}
  end.

send_request(Port, Function) ->
  Port ! {request, self(), Function},
  receive
    {Port, Result} ->
      Result;
    {'DOWN', _, process, Port, Reason} ->
      ?LOGERROR("~p received DOWN from port: ~p, reason: ~p", [Port, Reason]),
      exit(Reason)
  end.

send_asdu(ASDU, #data{
  state = State,
  port = Port,
  owner = Owner,
  name = Name
} = Data) ->
  Request = fun() -> iec60870_101:user_data_confirm(ASDU, State) end,
  case send_request(Port, Request) of
    error ->
      ?LOGERROR("~p failed to send asdu: ~p", [Name, ASDU]),
      Owner ! {send_error, self(), timeout},
      Data;
    NewState ->
      ?LOGDEBUG("~p successfully sent asdu", [Name]),
      Data#data{state = NewState}
  end.

%%% +--------------------------------------------------------------+
%%% |                         Shared port                          |
%%% +--------------------------------------------------------------+

start_port(Options) ->
  Client = self(),
  PID = spawn_link(fun() -> init_port(Client, Options) end),
  receive
    {ready, PID, PID} ->
      PID;
    {ready, PID, Port} ->
      link(Port),
      Port
  end.

init_port(Client, #{transport := #{name := Name}} = Options) ->
  RegisterName = list_to_atom(Name),
  case catch register(RegisterName, self()) of
    {'EXIT', _} ->
      case whereis(RegisterName) of
        Port when is_pid(Port) ->
          Client ! {ready, self(), Port};
        _ ->
          init_client(Client, Options)
      end;
    true ->
      case catch iec60870_ft12:start_link(maps:with([transport, address_size], Options)) of
        {'EXIT', Error} ->
          ?LOGERROR("shared port ~p failed to start transport layer (ft12), error: ~p", [Name, Error]),
          exit({transport_layer_init_failure, Error});
        PortFT12 ->
          process_flag(trap_exit, true),
          ?LOGDEBUG("shared port ~p starting...", [Name]),
          Client ! {ready, self(), self()},
          port_loop(#port_state{
            port_ft12 = PortFT12,
            name = Name,
            clients = #{}
          })
      end
  end.

port_loop(#port_state{port_ft12 = PortFT12, clients = Clients, name = Name} = SharedState) ->
  receive
    {request, From, Function} ->
      case Clients of
        #{From := true} ->
          From ! {self(), Function()};
        _Unexpected ->
          ?LOGWARNING("shard port ~p ignored request from undefined process: ~p", [From])
      end,
      port_loop(SharedState);

    {add_client, Client, Options} ->
      case iec60870_101:connect(Options#{portFT12 => PortFT12, direction => 0}) of
        error ->
          ?LOGERROR("shared port ~p failed to add client: ~p", [Name, Client]),
          Client ! {error, self(), timeout},
          State1 = check_stop(SharedState),
          port_loop(State1);
        ClientState ->
          ?LOGDEBUG("shared port ~p added client ~p", [Name, Client]),
          Client ! {ok, self(), ClientState},
          port_loop(SharedState#port_state{clients = Clients#{Client => true}})
      end;

    {'EXIT', PortFT12, Reason} ->
      ?LOGERROR("shared port ~p received EXIT from ft12, reason: ~p", [Name, Reason]),
      exit({transport_layer_failure, Reason});

    {'EXIT', Client, Reason} ->
      ?LOGDEBUG("shared port ~p received EXIT from client: ~p, reason: ~p", [Name, Client, Reason]),
      State1 = check_stop(SharedState#port_state{clients = maps:remove(Client, Clients)}),
      port_loop(State1);

    Unexpected ->
      ?LOGWARNING("shared port ~p received unexpected message: ~p", [Name, Unexpected]),
      port_loop(SharedState)
  end.

check_stop(#port_state{
  clients = Clients,
  port_ft12 = PortFT12,
  name = Name
} = State) ->
  if
    map_size(Clients) =:= 0 ->
      ?LOGINFO("shared port ~p terminating, no remaining clients...", [Name]),
      iec60870_ft12:stop(PortFT12),
      exit(shutdown);
    true ->
      State
  end.

%% Send ASDU to the owner if it exists
send_asdu_to_owner(_Owner, _ASDU = undefined) ->
  ok;
send_asdu_to_owner(Owner, ASDU) ->
  Owner ! {asdu, self(), ASDU}.

%% The server set the signal that it has data to send
check_access_demand(_ACD = 1) ->
  self() ! {access_demand, self()};
check_access_demand(_ACD) ->
  ok.