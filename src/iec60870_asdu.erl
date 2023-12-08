-module(iec60870_asdu).

-include("iec60870.hrl").
-include("asdu.hrl").

-export([
  get_settings/1,
  parse/2,
  build/2
]).

%% +--------------------------------------------------------------+
%% |                           Macros                             |
%% +--------------------------------------------------------------+

%% SQ (Structure Qualifier) bit specifies how information are addressed
-define(SQ_DISCONTINUOUS, 0).
-define(SQ_CONTINUOUS, 1).

%% Packet capacity
-define(MAX_PACKET_BYTE_SIZE, 255).

%% Constant sizes of header content
-define(TRANSPORT_CONSTANT_COST, 4).
-define(ASDU_CONSTANT_COST, 3).

%% +--------------------------------------------------------------+
%% |                             API                              |
%% +--------------------------------------------------------------+

parse(ASDU, #{
  ioa_size := IOABitSize,
  org_size := ORGBitSize,
  coa_size := COABitSize
}) ->
  {DUI, ObjectsBinary} = parse_dui(COABitSize, ORGBitSize, ASDU),
  Objects = construct_sequence(DUI, IOABitSize, ObjectsBinary),
  #{
    type := Type,
    t    := T,
    pn   := PN,
    cot  := COT,
    org  := ORG,
    coa  := COA
  } = DUI,
  ParsedObjects =
    [begin
       {Address, iec60870_type:parse_information_element(Type, Object)}
     end || {Address, Object} <- Objects],
  #asdu{
    type = Type,
    pn = PN,
    t = T,
    cot = COT,
    org = ORG,
    coa = COA,
    objects = ParsedObjects
  }.

build(#asdu{
  type = Type,
  cot = COT,
  objects = DataObjects
}, #{
  org := ORG,
  coa := COA,
  ioa_size := IOABitSize,
  org_size := ORGBitSize,
  coa_size := COABitSize
}) ->
  HeaderSize = (
      ?TRANSPORT_CONSTANT_COST
    + ?ASDU_CONSTANT_COST
    + ORGBitSize div 8
    + COABitSize div 8
  ),
  [{_IOA, Value} | _] = DataObjects,
  ElementSize =
    size(iec60870_type:create_information_element(Type, Value)) + (IOABitSize div 8),
  AvailableSize = ?MAX_PACKET_BYTE_SIZE - HeaderSize,
  MaxObjectsNumber = AvailableSize div ElementSize,
  InformationObjectsList =
    if
      length(DataObjects) > MaxObjectsNumber ->
        split(DataObjects, MaxObjectsNumber);
      true ->
        [DataObjects]
    end,
  [begin
    <<Type:8                         /integer,
      ?SQ_DISCONTINUOUS:1            /integer,
      (length(InformationObjects)):7 /integer,
      0:1, 0:1, COT:6                /little-integer,
      ORG:ORGBitSize                 /little-integer,
      COA:COABitSize                 /little-integer,
      (create_information_objects(Type, InformationObjects, IOABitSize))/binary>>
   end || InformationObjects <- InformationObjectsList].

get_settings(#{
  coa_size := COASize,
  org_size := ORGSize,
  ioa_size := IOASize
} = Settings) ->
  Settings#{
    coa_size => COASize * 8,
    org_size => ORGSize * 8,
    ioa_size => IOASize * 8
  }.

%% +--------------------------------------------------------------+
%% |                 Internal helper functions                    |
%% +--------------------------------------------------------------+

construct_sequence(#{sq := ?SQ_CONTINUOUS, no := NumberOfObjects}, IOASize, ObjectsBinary) ->
  <<Start:IOASize/little-integer, Sequence/binary>> = ObjectsBinary,
  ObjectSize = round(iec60870_lib:bytes_to_bits(size(Sequence) / NumberOfObjects)),
  ObjectsList = [<<Object:ObjectSize>> || <<Object:ObjectSize>> <= Sequence],
  lists:zip(lists:seq(Start, Start + NumberOfObjects - 1), ObjectsList);

construct_sequence(#{sq := ?SQ_DISCONTINUOUS, no := NumberOfObjects}, IOASize, ObjectsBinary) ->
  ObjectSize = round((iec60870_lib:bytes_to_bits(size(ObjectsBinary)) - IOASize * NumberOfObjects) / NumberOfObjects),
  [{Address, <<Object:ObjectSize>>} || <<Address:IOASize/little-integer, Object:ObjectSize>> <= ObjectsBinary].

create_information_objects(Type, DataObjects, IOABitSize) ->
  InformationObjectsList =
    [{IOA, iec60870_type:create_information_element(Type, Value)} || {IOA, Value} <- DataObjects],
  <<<<Address:IOABitSize/little-integer, Value/binary>> || {Address, Value} <- InformationObjectsList>>.

%% +--------------[ DUI Structure ]--------------+
%% | Type Identification (TypeID) - 1 byte       |
%% | Structure Qualifier (SQ)     - 1 bit        |
%% | Number of Objects   (NO)     - 7 bits       |
%% | Test                         - 1 bit        |
%% | Positive / Negative (P/N)    - 1 bit        |
%% | Cause of Transmission (COT)  - 6 bits       |
%% | Originator Address (ORG)     - 0 or 1 byte  |
%% | Common Address (COA)         - 1 or 2 bytes |
%% | ...Information objects...                   |
%% +---------------------------------------------+

%% Data Unit Identifier (DUI) parser
parse_dui(COASize, ORGSize,
  <<Type:8,
    SQ:1, NumberOfObjects:7,
    T:1, PN:1, COT:6,
    Rest/binary>>
) ->
  <<ORG:ORGSize,
    COA:COASize/little-integer,
    Body/binary>> = Rest,
  DUI = #{
    type => Type,
    sq   => SQ,
    no   => NumberOfObjects,
    t    => T,
    pn   => PN,
    cot  => COT,
    org  => ORG,
    coa  => COA
  },
  {DUI, Body};

parse_dui(_COASize, _ORGSize, InvalidASDU) ->
  throw({invalid_asdu_format, InvalidASDU}).

%% Splits objects depending on the maximum size which
%% on the other hand depends on the type of object
split(DataObjects, MaxSize) when length(DataObjects) > MaxSize ->
  {Head, Tail} = lists:split(MaxSize, DataObjects),
  [Head | split(Tail, MaxSize)];
split(DataObjects, _MaxSize)->
  [DataObjects].