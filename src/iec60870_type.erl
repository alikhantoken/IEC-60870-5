%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-module(iec60870_type).

-include("iec60870.hrl").
-include("asdu.hrl").

%%% +--------------------------------------------------------------+
%%% |                             API                              |
%%% +--------------------------------------------------------------+

-export([
  parse_information_element/2,
  create_information_element/2
]).

%%% +--------------------------------------------------------------+
%%% |                       Macros & Records                       |
%%% +--------------------------------------------------------------+

-define(MILLIS_IN_MINUTE, 60000).
-define(UNIX_EPOCH_DATE, {1970, 1, 1}).
-define(UNIX_EPOCH_SECONDS, 62167219200).
-define(CURRENT_MILLENNIUM, 2000).

%%% +--------------------------------------------------------------+
%%% |                           Parsing                            |
%%% +--------------------------------------------------------------+

%% Type 1. Single point information
parse_information_element(?M_SP_NA_1, <<SIQ>>) ->
  <<_Ignore:7, SPI:1>> = <<SIQ>>,
  #{value => SPI, siq => SIQ};

%% Type 2. Single point information with time tag
parse_information_element(?M_SP_TA_1, <<SIQ, Timestamp/binary>>) ->
  <<_Ignore:7, SPI:1>> = <<SIQ>>,
  #{value => SPI, siq => SIQ, ts => parse_cp24(Timestamp)};

%% Type 3. Double point information
parse_information_element(?M_DP_NA_1, <<DIQ>>) ->
  <<_Ignore:6, DPI:2>> = <<DIQ>>,
  #{value => DPI, diq => DIQ};

%% Type 4. Double point information with time tag
parse_information_element(?M_DP_TA_1, <<DIQ, Timestamp/binary>>) ->
  <<_Ignore:6, DPI:2>> = <<DIQ>>,
  #{value => DPI, diq => DIQ, ts => parse_cp24(Timestamp)};

%% Type 5. Step position information
parse_information_element(?M_ST_NA_1, <<VTI, QDS>>) ->
  <<_Ignore:1, Value:7/signed>> = <<VTI>>,
  #{value => Value, vti => VTI, qds => QDS};

%% Type 6. Step position information with time tag
parse_information_element(?M_ST_TA_1, <<VTI, QDS, Timestamp/binary>>) ->
  <<_Ignore:1, Value:7/signed>> = <<VTI>>,
  #{value => Value, vti => VTI, qds => QDS, ts => parse_cp24(Timestamp)};

%% Type 7. Bit string of 32 bit
parse_information_element(?M_BO_NA_1, <<BSI:32/little-unsigned, QDS>>) ->
  #{value => BSI, qds => QDS};

%% Type 8. Bit string of 32 bit with time tag
parse_information_element(?M_BO_TA_1, <<BSI:32/little-unsigned, QDS, Timestamp/binary>>) ->
  #{value => BSI, qds => QDS, ts => parse_cp24(Timestamp)};

%% Type 9. Measured value, normalized value
parse_information_element(?M_ME_NA_1, <<NVA:16/little-signed, QDS>>) ->
  #{value => parse_nva(NVA), qds => QDS};

%% Type 10. Measured value, normalized value with time tag
parse_information_element(?M_ME_TA_1, <<NVA:16/little-signed, QDS, Timestamp/binary>>) ->
  #{value => parse_nva(NVA), qds => QDS, ts => parse_cp24(Timestamp)};

%% Type 11. Measured value, scaled value
parse_information_element(?M_ME_NB_1, <<SVA:16/little-signed, QDS>>) ->
  #{value => SVA, qds => QDS};

%% Type 12. Measured value, scaled value with time tag
parse_information_element(?M_ME_TB_1, <<SVA:16/little-signed, QDS, Timestamp/binary>>) ->
  #{value => SVA, qds => QDS, ts => parse_cp24(Timestamp)};

%% Type 13. Measured value, short floating point
parse_information_element(?M_ME_NC_1, <<Value:32/little-signed-float, QDS>>) ->
  #{value => Value, qds => QDS};

%% Type 14. Measured value, short floating point with time tag
parse_information_element(?M_ME_TC_1, <<Value:32/little-signed-float, QDS, Timestamp/binary>>) ->
  #{value => Value, qds => QDS, ts => parse_cp24(Timestamp)};

%% Type 15. Integrated totals
parse_information_element(?M_IT_NA_1, <<BCR:40>>) ->
  <<Value:32/little-signed, _Ignore:8>> = <<BCR:40>>,
  #{value => Value, bcr => BCR};

%% Type 16. Integrated totals with time tag
parse_information_element(?M_IT_TA_1, <<BCR:40, Timestamp/binary>>) ->
  <<Value:32/little-signed, _Ignore:8>> = <<BCR:40>>,
  #{value => Value, bcr => BCR, ts => parse_cp24(Timestamp)};

%% Type 17. Protection equipment with time tag
parse_information_element(?M_EP_TA_1, <<SEP, Duration:16/little, Timestamp/binary>>) ->
  <<_Ignore:6, ES:2>> = <<SEP>>,
  #{value => ES, sep => SEP, duration => Duration, ts => parse_cp24(Timestamp)};

%% Type 18. Packed events of protection equipment with time tag
parse_information_element(?M_EP_TB_1, <<SPE, QDP, Duration:16/little, Timestamp24/binary>>) ->
  #{value => SPE, qdp => QDP, duration => Duration, ts => parse_cp24(Timestamp24)};

%% Type 19. Packed output circuit information of protection equipment with time tag
parse_information_element(?M_EP_TC_1, <<OCI, QDP, Duration:16/little, Timestamp24/binary>>) ->
  #{value => OCI, qdp => QDP, duration => Duration, ts => parse_cp24(Timestamp24)};

%% Type 20. Packed single-point information with status change detection
parse_information_element(?M_PS_NA_1, <<SCD:32/little, QDS>>) ->
  #{value => SCD, qds => QDS};

%% Type 21. Measured value, normalized value without QDS
parse_information_element(?M_ME_ND_1, <<NVA:16/little-signed>>) ->
  #{value => parse_nva(NVA)};

%% Type 30. Single point information with time tag
parse_information_element(?M_SP_TB_1, <<SIQ, Timestamp/binary>>) ->
  <<_Ignore:7, SPI:1>> = <<SIQ>>,
  #{value => SPI, siq => SIQ, ts => parse_cp56(Timestamp)};

%% Type 31. Double point information with time tag
parse_information_element(?M_DP_TB_1, <<DIQ, Timestamp/binary>>) ->
  <<_Ignore:6, DPI:2>> = <<DIQ>>,
  #{value => DPI, diq => DIQ, ts => parse_cp56(Timestamp)};

%% Type 32. Step position information with time tag
parse_information_element(?M_ST_TB_1, <<VTI, QDS, Timestamp/binary>>) ->
  <<_Ignore:1, Value:7/signed>> = <<VTI>>,
  #{value => Value, vti => VTI, qds => QDS, ts => parse_cp56(Timestamp)};

%% Type 33. Bit string of 32 bit with time tag
parse_information_element(?M_BO_TB_1, <<BSI:32/little-unsigned, QDS, Timestamp/binary>>) ->
  #{value => BSI, qds => QDS, ts => parse_cp56(Timestamp)};

%% Type 34. Measured value, normalized value with time tag
parse_information_element(?M_ME_TD_1, <<NVA:16/little-signed, QDS, Timestamp/binary>>) ->
  #{value => parse_nva(NVA), qds => QDS, ts => parse_cp56(Timestamp)};

%% Type 35. Measured value, scaled value with time tag
parse_information_element(?M_ME_TE_1, <<SVA:16/little-signed, QDS, Timestamp/binary>>) ->
  #{value => SVA, qds => QDS, ts => parse_cp56(Timestamp)};

%% Type 36. Measured value, short floating point value with time tag
parse_information_element(?M_ME_TF_1, <<Value:32/little-signed-float, QDS, Timestamp/binary>>) ->
  #{value => Value, qds => QDS, ts => parse_cp56(Timestamp)};

%% Type 37. Integrated totals with time tag
parse_information_element(?M_IT_TB_1, <<BCR:40, Timestamp/binary>>) ->
  <<Value:32/little-signed, _Ignore:8>> = <<BCR:40>>,
  #{value => Value, bcr => BCR, ts => parse_cp56(Timestamp)};

%% Type 38. Event of protection equipment with time tag
parse_information_element(?M_EP_TD_1, <<SEP, Interval:16/little-unsigned, Timestamp/binary>>) ->
  <<_Ignore:6, ES:2>> = <<SEP>>,
  #{value => ES, sep => SEP, interval => Interval, ts => parse_cp56(Timestamp)};

%% Type 45: Single command
parse_information_element(?C_SC_NA_1, <<SCO>>) ->
  <<_Ignore:7, SCS:1>> = <<SCO>>,
  #{value => SCS, sco => SCO};

%% Type 46: Double command
parse_information_element(?C_DC_NA_1, <<DCO>>) ->
  <<_Ignore:6, DCS:2>> = <<DCO>>,
  #{value => DCS, dco => DCO};

%% Type 47: Regulating step command
parse_information_element(?C_RC_NA_1, <<RCO>>) ->
  <<_Ignore:6, RCS:2>> = <<RCO>>,
  #{value => RCS, rco => RCO};

%% Type 48: Set point command, normalized value
parse_information_element(?C_SE_NA_1, <<NVA:16/little-signed, QOS>>) ->
  #{value => parse_nva(NVA), qos => QOS};

%% Type 49: Set point command, scaled value
parse_information_element(?C_SE_NB_1, <<SVA:16/little-signed, QOS>>) ->
  #{value => SVA, qos => QOS};

%% Type 50: Set point command, short floating point value
parse_information_element(?C_SE_NC_1, <<Value:32/little-signed-float, QOS>>) ->
  #{value => Value, qos => QOS};

%% Type 51: Bit string 32 bit
parse_information_element(?C_BO_NA_1, <<BSI:32/little-unsigned>>) ->
  #{value => BSI};

%% Type 58: Single command with time tag
parse_information_element(?C_SC_TA_1, <<SCO, Timestamp/binary>>) ->
  <<_Ignore:7, SCS:1>> = <<SCO>>,
  #{value => SCS, sco => SCO, ts => parse_cp56(Timestamp)};

%% Type 59: Double command with time tag
parse_information_element(?C_DC_TA_1, <<DCO, Timestamp/binary>>) ->
  <<_Ignore:6, DCS:2>> = <<DCO>>,
  #{value => DCS, dco => DCO, ts => parse_cp56(Timestamp)};

%% Type 60: Regulating step command with time tag
parse_information_element(?C_RC_TA_1, <<RCO, Timestamp/binary>>) ->
  <<_Ignore:6, RCS:2>> = <<RCO>>,
  #{value => RCS, rco => RCO, ts => parse_cp56(Timestamp)};

%% Type 61: Set point command, normalized value with time tag
parse_information_element(?C_SE_TA_1, <<NVA:16/little-signed, QOS, Timestamp/binary>>) ->
  #{value => parse_nva(NVA), qos => QOS, ts => parse_cp56(Timestamp)};

%% Type 62: Set point command, scaled value with time tag
parse_information_element(?C_SE_TB_1, <<SVA:16/little-signed, QOS, Timestamp/binary>>) ->
  #{value => SVA, qos => QOS, ts => parse_cp56(Timestamp)};

%% Type 63: Set point command, short floating point value with time tag
parse_information_element(?C_SE_TC_1, <<Value:32/little-signed-float, QOS, Timestamp/binary>>) ->
  #{value => Value, qos => QOS, ts => parse_cp56(Timestamp)};

%% Type 64: Bit string 32 bit with time tag
parse_information_element(?C_BO_TA_1, <<BSI:32/little-unsigned, Timestamp/binary>>) ->
  #{value => BSI, ts => parse_cp56(Timestamp)};

%% Type 70. End of initialization
parse_information_element(?M_EI_NA_1, <<COI>>) ->
  <<_Ignore:1, Value:7>> = <<COI>>,
  #{value => Value, coi => COI};

%% Type 100. Group request
parse_information_element(?C_IC_NA_1, <<GroupID>>) ->
  GroupID - ?COT_GROUP_MIN;

%% Type 101. Group counter request
parse_information_element(?C_CI_NA_1, <<GroupCounterID>>) ->
  GroupCounterID - ?COT_GROUP_COUNTER_MIN;

%% Type 103. Clock synchronization
parse_information_element(?C_CS_NA_1, Timestamp) ->
  parse_cp56(Timestamp);

parse_information_element(Type, Value) ->
  case is_type_supported(Type) of
    true -> throw({invalid_object, Type, Value});
    false -> throw({invalid_object_type, Type})
  end.

%% +--------------------------------------------------------------+
%% |                          Creating                            |
%% +--------------------------------------------------------------+

%% Type 1. Single point information
create_information_element(?M_SP_NA_1, #{value := SPI} = Object) ->
  SIQ = maps:get(siq, Object, 0),
  <<Rest:7, _Ignore:1>> = <<SIQ>>,
  <<Rest:7, (round(SPI)):1>>;

%% Type 2. Single point information with time tag
create_information_element(?M_SP_TA_1, #{value := SPI} = Object) ->
  SIQ = maps:get(siq, Object, 0),
  Timestamp = maps:get(ts, Object, undefined),
  <<Rest:7, _Ignore:1>> = <<SIQ>>,
  <<Rest:7, (round(SPI)):1, (get_cp24(Timestamp))/binary>>;

%% Type 3. Double point information
create_information_element(?M_DP_NA_1, #{value := DPI} = Object) ->
  DIQ = maps:get(diq, Object, 0),
  <<Rest:6, _Ignore:2>> = <<DIQ>>,
  <<Rest:6, (round(DPI)):2>>;

%% Type 4. Double point information with time tag
create_information_element(?M_DP_TA_1, #{value := DPI} = Object) ->
  DIQ = maps:get(diq, Object, 0),
  Timestamp = maps:get(ts, Object, undefined),
  <<Rest:6, _Ignore:2>> = <<DIQ>>,
  <<Rest:6, (round(DPI)):2, (get_cp24(Timestamp))/binary>>;

%% Type 5. Step position information
create_information_element(?M_ST_NA_1, #{value := Value} = Object) ->
  VTI = maps:get(vti, Object, 0),
  QDS = maps:get(qds, Object, 0),
  <<State:1, _Ignore:7>> = <<VTI>>,
  <<State:1, (round(Value)):7/signed, QDS>>;

%% Type 6. Step position information with time tag
create_information_element(?M_ST_TA_1, #{value := Value} = Object) ->
  VTI = maps:get(vti, Object, 0),
  QDS = maps:get(qds, Object, 0),
  Timestamp = maps:get(ts, Object, undefined),
  <<State:1, _Ignore:7>> = <<VTI>>,
  <<State:1, (round(Value)):7/signed, QDS, (get_cp24(Timestamp))/binary>>;

%% Type 7. Bit string of 32 bit
create_information_element(?M_BO_NA_1, #{value := BSI} = Object) ->
  QDS = maps:get(qds, Object, 0),
  <<(round(BSI)):32/little-unsigned, QDS>>;

%% Type 8. Bit string of 32 bit with time tag
create_information_element(?M_BO_TA_1, #{value := BSI} = Object) ->
  QDS = maps:get(qds, Object, 0),
  Timestamp = maps:get(ts, Object, undefined),
  <<(round(BSI)):32/little-unsigned, QDS, (get_cp24(Timestamp))/binary>>;

%% Type 9. Measured value, normalized value
create_information_element(?M_ME_NA_1, #{value := NVA} = Object) ->
  QDS = maps:get(qds, Object, 0),
  <<(get_nva(NVA)):16/little-signed, QDS>>;

%% Type 10. Measured value, normalized value with time tag
create_information_element(?M_ME_TA_1, #{value := NVA} = Object) ->
  QDS = maps:get(qds, Object, 0),
  Timestamp = maps:get(ts, Object, undefined),
  <<(get_nva(NVA)):16/little-signed, QDS, (get_cp24(Timestamp))/binary>>;

%% Type 11. Measured value, scaled value
create_information_element(?M_ME_NB_1, #{value := SVA} = Object) ->
  QDS = maps:get(qds, Object, 0),
  <<(round(SVA)):16/little-signed, QDS>>;

%% Type 12. Measured value, scaled value with time tag
create_information_element(?M_ME_TB_1, #{value := SVA} = Object) ->
  QDS = maps:get(qds, Object, 0),
  Timestamp = maps:get(ts, Object, undefined),
  <<(round(SVA)):16/little-signed, QDS, (get_cp24(Timestamp))/binary>>;

%% Type 13. Measured value, short floating point
create_information_element(?M_ME_NC_1, #{value := Value} = Object) ->
  QDS = maps:get(qds, Object, 0),
  <<Value:32/little-signed-float, QDS>>;

%% Type 14. Measured value, short floating point with time tag
create_information_element(?M_ME_TC_1, #{value := Value} = Object) ->
  QDS = maps:get(qds, Object, 0),
  Timestamp = maps:get(ts, Object, undefined),
  <<Value:32/little-signed-float, QDS, (get_cp24(Timestamp))/binary>>;

%% Type 15. Integrated totals
create_information_element(?M_IT_NA_1, #{value := Value} = Object) ->
  BCR = maps:get(bcr, Object, 0),
  <<_Ignore:32, Rest>> = <<BCR:40>>,
  <<(round(Value)):32/little-signed, Rest>>;

%% Type 16. Integrated totals with time tag
create_information_element(?M_IT_TA_1, #{value := Value} = Object) ->
  BCR = maps:get(bcr, Object, 0),
  Timestamp = maps:get(ts, Object, undefined),
  <<_Ignore:32, Rest>> = <<BCR:40>>,
  <<(round(Value)):32/little-signed, Rest, (get_cp24(Timestamp))/binary>>;

%% Type 17. Protection equipment with time tag
create_information_element(?M_EP_TA_1, #{value := ES} = Object) ->
  SEP = maps:get(sep, Object, 0),
  Duration = maps:get(duration, Object, undefined),
  Timestamp = maps:get(ts, Object, undefined),
  <<Rest:6, _Ignore:2>> = <<SEP>>,
  <<Rest:6, (round(ES)):2, (get_cp16(Duration)):16/little, (get_cp24(Timestamp))/binary>>;

%% Type 18. Packed events of protection equipment with time tag
create_information_element(?M_EP_TB_1, #{value := SPE} = Object) ->
  QDP = maps:get(qdp, Object, 0),
  Duration = maps:get(duration, Object, undefined),
  Timestamp = maps:get(ts, Object, undefined),
  <<SPE, QDP, (get_cp16(Duration)):16/little, (get_cp24(Timestamp))/binary>>;

%% Type 19. Packed output circuit information of protection equipment with time tag
create_information_element(?M_EP_TC_1, #{value := OCI} = Object) ->
  QDP = maps:get(qdp, Object, 0),
  Duration = maps:get(duration, Object, undefined),
  Timestamp = maps:get(ts, Object, undefined),
  <<OCI, QDP, (get_cp16(Duration)):16/little, (get_cp24(Timestamp))/binary>>;

%% Type 20. Packed single-point information with status change detection
create_information_element(?M_PS_NA_1, #{value := SCD} = Object) ->
  QDS = maps:get(qds, Object, 0),
  <<(round(SCD)):32/little, QDS>>;

%% Type 21. Measured value, normalized value without QDS
create_information_element(?M_ME_ND_1, #{value := NVA}) ->
  <<(get_nva(NVA)):16/little-signed>>;

%% Type 30. Single point information with time tag
create_information_element(?M_SP_TB_1, #{value := SPI} = Object) ->
  SIQ = maps:get(siq, Object, 0),
  Timestamp = maps:get(ts, Object, undefined),
  <<Rest:7, _Ignore:1>> = <<SIQ>>,
  <<Rest:7, (round(SPI)):1, (get_cp56(Timestamp))/binary>>;

%% Type 31. Double point information with time tag
create_information_element(?M_DP_TB_1, #{value := DPI} = Object) ->
  DIQ = maps:get(diq, Object, 0),
  Timestamp = maps:get(ts, Object, undefined),
  <<Rest:6, _Ignore:2>> = <<DIQ>>,
  <<Rest:6, (round(DPI)):2, (get_cp56(Timestamp))/binary>>;

%% Type 32. Step position information with time tag
create_information_element(?M_ST_TB_1, #{value := Value} = Object) ->
  VTI = maps:get(vti, Object, 0),
  QDS = maps:get(qds, Object, 0),
  Timestamp = maps:get(ts, Object, undefined),
  <<State:1, _Ignore:7>> = <<VTI>>,
  <<State:1, (round(Value)):7, QDS, (get_cp56(Timestamp))/binary>>;

%% Type 33. Bit string of 32 bit with time tag
create_information_element(?M_BO_TB_1, #{value := BSI} = Object) ->
  QDS = maps:get(qds, Object, 0),
  Timestamp = maps:get(ts, Object, undefined),
  <<(round(BSI)):32/little-unsigned, QDS, (get_cp56(Timestamp))/binary>>;

%% Type 34. Measured value, normalized value with time tag
create_information_element(?M_ME_TD_1, #{value := NVA} = Object) ->
  QDS = maps:get(qds, Object, 0),
  Timestamp = maps:get(ts, Object, undefined),
  <<(get_nva(NVA)):16/little-signed, QDS, (get_cp56(Timestamp))/binary>>;

%% Type 35. Measured value, scaled value with time tag
create_information_element(?M_ME_TE_1, #{value := SVA} = Object) ->
  QDS = maps:get(qds, Object, 0),
  Timestamp = maps:get(ts, Object, undefined),
  <<(round(SVA)):16/little-signed, QDS, (get_cp56(Timestamp))/binary>>;

%% Type 36. Measured value, short floating point value with time tag
create_information_element(?M_ME_TF_1, #{value := Value} = Object) ->
  QDS = maps:get(qds, Object, 0),
  Timestamp = maps:get(ts, Object, undefined),
  <<Value:32/little-signed-float, QDS, (get_cp56(Timestamp))/binary>>;

%% Type 37. Integrated totals with time tag
create_information_element(?M_IT_TB_1, #{value := Value} = Object) ->
  BCR = maps:get(bcr, Object, 0),
  Timestamp = maps:get(ts, Object, undefined),
  <<_Ignore:32, Rest:8>> = <<BCR:40>>,
  <<(round(Value)):32/little-signed, Rest:8, (get_cp56(Timestamp))/binary>>;

%% Type 38. Event of protection equipment with time tag
create_information_element(?M_EP_TD_1, #{value := ES} = Object) ->
  SEP = maps:get(sep, Object, 0),
  Interval = maps:get(interval, Object, 0),
  Timestamp = maps:get(ts, Object, undefined),
  <<Rest:6, _Ignore:2>> = <<SEP>>,
  <<Rest:6, (round(ES)):2, Interval:16/little-unsigned, (get_cp56(Timestamp))/binary>>;

%% Type 45: Single command
create_information_element(?C_SC_NA_1, #{value := SCS} = Object) ->
  SCO = maps:get(sco, Object, 0),
  <<Rest:7, _Ignore:1>> = <<SCO>>,
  <<Rest:7, (round(SCS)):1>>;

%% Type 46: Double command
create_information_element(?C_DC_NA_1, #{value := DCS} = Object) ->
  DCO = maps:get(dco, Object, 0),
  <<Rest:6, _Ignore:2>> = <<DCO>>,
  <<Rest:6, (round(DCS)):2>>;

%% Type 47: Regulating step command
create_information_element(?C_RC_NA_1, #{value := RCS} = Object) ->
  RCO = maps:get(rco, Object, 0),
  <<Rest:6, _Ignore:2>> = <<RCO>>,
  <<Rest:6, (round(RCS)):2>>;

%% Type 48: Set point command, normalized value
create_information_element(?C_SE_NA_1, #{value := NVA} = Object) ->
  QOS = maps:get(qos, Object, 0),
  <<(get_nva(NVA)):16/little-signed, QOS>>;

%% Type 49: Set point command, scaled value
create_information_element(?C_SE_NB_1, #{value := SVA} = Object) ->
  QOS = maps:get(qos, Object, 0),
  <<(round(SVA)):16/little-signed, QOS>>;

%% Type 50: Set point command, short floating point value
create_information_element(?C_SE_NC_1, #{value := Value} = Object) ->
  QOS = maps:get(qos, Object, 0),
  <<Value:32/little-signed-float, QOS>>;

%% Type 51: Bit string 32 bit
create_information_element(?C_BO_NA_1, #{value := BSI}) ->
  <<(round(BSI)):32/little-unsigned>>;

%% Type 58: Single command with time tag
create_information_element(?C_SC_TA_1, #{value := SCS} = Object) ->
  SCO = maps:get(sco, Object, 0),
  Timestamp = maps:get(ts, Object, undefined),
  <<Rest:7, _Ignore:1>> = <<SCO>>,
  <<Rest:7, (round(SCS)):1, (get_cp56(Timestamp))/binary>>;

%% Type 59: Double command with time tag
create_information_element(?C_DC_TA_1, #{value := DCS} = Object) ->
  DCO = maps:get(dco, Object, 0),
  Timestamp = maps:get(ts, Object, undefined),
  <<Rest:6, _Ignore:2>> = <<DCO>>,
  <<Rest:6, (round(DCS)):2, (get_cp56(Timestamp))/binary>>;

%% Type 60: Regulating step command with time tag
create_information_element(?C_RC_TA_1, #{value := RCS} = Object) ->
  RCO = maps:get(rco, Object, 0),
  Timestamp = maps:get(ts, Object, undefined),
  <<Rest:6, _Ignore:2>> = <<RCO>>,
  <<Rest:6, (round(RCS)):2, (get_cp56(Timestamp))/binary>>;

%% Type 61: Set point command, normalized value with time tag
create_information_element(?C_SE_TA_1, #{value := NVA} = Object) ->
  QOS = maps:get(qos, Object, 0),
  Timestamp = maps:get(ts, Object, undefined),
  <<(get_nva(NVA)):16/little-signed, QOS, (get_cp56(Timestamp))/binary>>;

%% Type 62: Set point command, scaled value with time tag
create_information_element(?C_SE_TB_1, #{value := SVA} = Object) ->
  QOS = maps:get(qos, Object, 0),
  Timestamp = maps:get(ts, Object, undefined),
  <<(round(SVA)):16/little-signed, QOS, (get_cp56(Timestamp))/binary>>;

%% Type 63: Set point command, short floating point value with time tag
create_information_element(?C_SE_TC_1, #{value := Value} = Object) ->
  QOS = maps:get(qos, Object, 0),
  Timestamp = maps:get(ts, Object, undefined),
  <<Value:32/little-signed-float, QOS, (get_cp56(Timestamp))/binary>>;

%% Type 64: Bit string 32 bit with time tag
create_information_element(?C_BO_TA_1, #{value := BSI} = Object) ->
  Timestamp = maps:get(ts, Object, undefined),
  <<(round(BSI)):32/little-unsigned, (get_cp56(Timestamp))/binary>>;

%% Type 70. End of initialization
create_information_element(?M_EI_NA_1, #{value := Value} = Object) ->
  COI = maps:get(coi, Object, 0),
  <<InitValue:1, _Ignore:7>> = <<COI>>,
  <<InitValue:1, (round(Value)):7>>;

%% Type 100. Group request
create_information_element(?C_IC_NA_1, GroupID) ->
  <<(GroupID + ?COT_GROUP_MIN)>>;

%% Type 101. Group counter request
create_information_element(?C_CI_NA_1, GroupCounterID) ->
  <<(GroupCounterID + ?COT_GROUP_COUNTER_MIN)>>;

%% Type 103. Clock synchronization
create_information_element(?C_CS_NA_1, Timestamp) ->
  get_cp56(Timestamp);

create_information_element(OtherType, _) -> throw({unsupported_object_type, OtherType}).

%% +--------------------------------------------------------------+
%% |                     Internal functions                       |
%% +--------------------------------------------------------------+

parse_cp24(<<
  Millis:16/little-integer,
  _Reserved1:2,
  Minutes:6,
  _IgnoredRest/binary
>>) ->
  Millis + (Minutes * ?MILLIS_IN_MINUTE);
parse_cp24(InvalidTimestamp) ->
  ?LOGWARNING("Invalid CP24 has been received: ~p", [InvalidTimestamp]),
  throw({invalid_object_ts, InvalidTimestamp}).

parse_cp56(<<
  Millis:16 /little-integer,
  _R1:2,
  Minutes:6,
  _R2:3,
  Hours:5,
  _WD:3,
  Day:5,
  _R3:4,
  Month:4,
  _R4:1,
  Year:7
>> = Timestamp) ->
  try
    DateTime =
      {{Year + ?CURRENT_MILLENNIUM, Month, Day}, {Hours, Minutes, millis_to_seconds(Millis)}},
    [UTC] = calendar:local_time_to_universal_time_dst(DateTime),
    GregorianSeconds = calendar:datetime_to_gregorian_seconds(UTC),
    seconds_to_millis(GregorianSeconds - ?UNIX_EPOCH_SECONDS)
  catch
    _:Error ->
      ?LOGERROR("CP56 parse error: ~p, timestamp: ~p", [Error, Timestamp]),
      none
  end;
parse_cp56(InvalidTimestamp) ->
  ?LOGWARNING("Invalid CP56 has been received: ~p", [InvalidTimestamp]),
  throw({invalid_object_ts, InvalidTimestamp}).

get_cp16(Value) when is_integer(Value) ->
  Value;
get_cp16(Anything) ->
  ?LOGWARNING("CP16 received invalid timestamp: ~p", [Anything]),
  get_cp16(0).

get_cp24(TotalMillis) when is_integer(TotalMillis) ->
  try
    Remainder = TotalMillis rem ?MILLIS_IN_MINUTE,
    {Millis, Minutes} =
      case TotalMillis div ?MILLIS_IN_MINUTE of
        %% Max value of 6 bits for the minutes field
        Value when Value > 63 ->
          {Remainder + round(Value - 63) * ?MILLIS_IN_MINUTE, 63};
        Value ->
          {Remainder, Value}
      end,
    <<(round(Millis)):16/little-integer, 16#00:2, (round(Minutes)):6>>
  catch
    _:Error ->
      ?LOGERROR("CP24 get error: ~p, timestamp: ~p", [Error, TotalMillis]),
      undefined
  end;
get_cp24(Anything) ->
  ?LOGWARNING("CP24 received invalid timestamp: ~p", [Anything]),
  get_cp24(0).

get_cp56(PosixTimestamp) when is_integer(PosixTimestamp) ->
  try
    GregorianSeconds = millis_to_seconds(PosixTimestamp) + ?UNIX_EPOCH_SECONDS,
    UTC = calendar:gregorian_seconds_to_datetime(GregorianSeconds),
    {{Year, Month, Day}, {Hour, Minute, Seconds}} =
      calendar:universal_time_to_local_time(UTC),
    WeekDay = calendar:day_of_the_week(Year, Month, Day),
    <<(seconds_to_millis(Seconds)):16/little-integer,
      16#00:2,
      Minute:6,
      16#00:3,
      Hour:5,
      WeekDay:3,
      Day:5,
      16#00:4,
      Month:4,
      16#00:1,
      (Year - ?CURRENT_MILLENNIUM):7>>
  catch
    _:Error ->
      ?LOGERROR("CP56 get error: ~p, timestamp: ~p", [Error, PosixTimestamp]),
      undefined
  end;
get_cp56(Anything) ->
  ?LOGWARNING("CP56 received invalid timestamp: ~p", [Anything]),
  get_cp56(erlang:system_time(millisecond)).

millis_to_seconds(Millis) -> Millis div 1000.
seconds_to_millis(Seconds) -> Seconds * 1000.

-define(SHORT_INT_MIN_VALUE, -32768).
-define(SHORT_INT_MAX_VALUE, 32767).

%%% +--------------------------------------------------------------+
%%% |                   NVA parsing and building                   |
%%% +--------------------------------------------------------------+

%% Range = Short Int Max - Short Int Min
-define(DELTA_X, 65535).

%% Formula for normalization [-1, 1]:
%% x' = ((2 * (x - xMin)) / (xMax - xMin)) - 1.
parse_nva(Value) ->
  ((2 * (Value - ?SHORT_INT_MIN_VALUE)) / ?DELTA_X) - 1.

%% Inverse formula:
%% x = ((xMax - xMin) * ((x' + 1) / 2)) + xMin.
get_nva(Value) ->
  trunc(((?DELTA_X * (Value + 1)) / 2) + ?SHORT_INT_MIN_VALUE).

is_type_supported(Type)
  when (Type >= ?M_SP_NA_1 andalso Type =< ?M_ME_ND_1) orelse
       (Type >= ?M_SP_TB_1 andalso Type =< ?M_EI_NA_1) orelse
       (Type >= ?C_SC_NA_1 andalso Type =< ?C_BO_NA_1) orelse
       (Type >= ?C_SC_TA_1 andalso Type =< ?C_BO_TA_1) orelse
       (Type >= ?C_IC_NA_1 andalso Type =< ?C_CS_NA_1) -> true;
is_type_supported(_Type) -> false.