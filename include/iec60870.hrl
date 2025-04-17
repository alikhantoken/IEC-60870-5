%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-ifndef(iec60870).
-define(iec60870, 1).

%%-------------------------------------------------------------------------------
%% LOGGING
%%-------------------------------------------------------------------------------
-ifndef(TEST).

-define(MFA_METADATA, #{
  mfa => {?MODULE, ?FUNCTION_NAME, ?FUNCTION_ARITY},
  line => ?LINE
}).

-define(LOGERROR(Text),          logger:error(Text, [], ?MFA_METADATA)).
-define(LOGERROR(Text,Params),   logger:error(Text, Params, ?MFA_METADATA)).
-define(LOGWARNING(Text),        logger:warning(Text, [], ?MFA_METADATA)).
-define(LOGWARNING(Text,Params), logger:warning(Text, Params, ?MFA_METADATA)).
-define(LOGINFO(Text),           logger:info(Text, [], ?MFA_METADATA)).
-define(LOGINFO(Text,Params),    logger:info(Text, Params, ?MFA_METADATA)).
-define(LOGDEBUG(Text),          logger:debug(Text, [], ?MFA_METADATA)).
-define(LOGDEBUG(Text,Params),   logger:debug(Text, Params, ?MFA_METADATA)).

-else.

-define(LOGERROR(Text),           ct:pal("error: " ++ Text)).
-define(LOGERROR(Text, Params),   ct:pal("error: " ++ Text, Params)).
-define(LOGWARNING(Text),         ct:pal("warning: " ++ Text)).
-define(LOGWARNING(Text, Params), ct:pal("warning: " ++ Text, Params)).
-define(LOGINFO(Text),            ct:pal("info: " ++ Text)).
-define(LOGINFO(Text, Params),    ct:pal("info: " ++ Text, Params)).
-define(LOGDEBUG(Text),           ct:pal("debug: " ++ Text)).
-define(LOGDEBUG(Text, Params),   ct:pal("debug: " ++ Text, Params)).

-endif.

%% Structure Qualifier (SQ) types:
%% 0 - Different IOAs
%% 1 - Continuous IOAs
-define(SQ_0, 16#00:1).
-define(SQ_1, 16#01:1).

%% Monitor direction types
-define(M_SP_NA_1, 16#01). %  1: SIQ                                     | Single point information
-define(M_SP_TA_1, 16#02). %  2: SIQ + CP24Time2A                        | Single point information with time tag
-define(M_DP_NA_1, 16#03). %  3: DIQ                                     | Double point information
-define(M_DP_TA_1, 16#04). %  4: DIQ + CP24Time2A                        | Double point information with time tag
-define(M_ST_NA_1, 16#05). %  5: VTI + QDS                               | Step position information
-define(M_ST_TA_1, 16#06). %  6: VTI + QDS + CP24Time2A                  | Step position information with time tag
-define(M_BO_NA_1, 16#07). %  7: BSI + QDS                               | Bit string of 32 bit
-define(M_BO_TA_1, 16#08). %  8: BSI + QDS + CP24Time2A                  | Bit string of 32 bit with time tag
-define(M_ME_NA_1, 16#09). %  9: NVA + QDS                               | Measured value, normalized value
-define(M_ME_TA_1, 16#0A). % 10: NVA + QDS + CP24Time2A                  | Measured value, normalized value with time tag
-define(M_ME_NB_1, 16#0B). % 11: SVA + QDS                               | Measured value, scaled value
-define(M_ME_TB_1, 16#0C). % 12: SVA + QDS + CP24Time2A                  | Measured value, scaled value with time tag
-define(M_ME_NC_1, 16#0D). % 13: IEEE STD 754 + QDS                      | Measured value, short floating point
-define(M_ME_TC_1, 16#0E). % 14: IEEE STD 754 + QDS + CP24Time2A         | Measured value, short floating point with time tag
-define(M_IT_NA_1, 16#0F). % 15: BCR                                     | Integrated totals
-define(M_IT_TA_1, 16#10). % 16: BCR + CP24Time2A                        | Integrated totals with time tag
-define(M_EP_TA_1, 16#11). % 17: CP16Time2A + CP24Time2A                 | Protection equipment with time tag
-define(M_EP_TB_1, 16#12). % 18: SEP + QDP + C + CP16Time2A + CP24Time2A | Packed events of protection equipment with time tag
-define(M_EP_TC_1, 16#13). % 19: OCI + QDP + CP16Time2A + CP24Time2A     | Packed output circuit information of protection equipment with time tag
-define(M_PS_NA_1, 16#14). % 20: SCD + QDS                               | Packed single-point information with status change detection
-define(M_ME_ND_1, 16#15). % 21: NVA                                     | Measured value, normalized value without QDS
%% There are no types from 22 to 29
-define(M_SP_TB_1, 16#1E). % 30: SIQ + CP56Time2A                        | Single point information with time tag
-define(M_DP_TB_1, 16#1F). % 31: DIQ + CP56Time2A                        | Double point information with time tag
-define(M_ST_TB_1, 16#20). % 32: VTI + QDS + CP56Time2A                  | Step position information with time tag
-define(M_BO_TB_1, 16#21). % 33: BSI + QDS + CP56Time2A                  | Bit string of 32 bit with time tag
-define(M_ME_TD_1, 16#22). % 34: NVA + QDS + CP56Time2A                  | Measured value, normalized value with time tag
-define(M_ME_TE_1, 16#23). % 35: SVA + QDS + CP56Time2A                  | Measured value, scaled value with time tag
-define(M_ME_TF_1, 16#24). % 36: IEEE STD 754 + QDS + CP56Time2A         | Measured value, short floating point value with time tag
-define(M_IT_TB_1, 16#25). % 37: BCR + CP56Time2A                        | Integrated totals with time tag
-define(M_EP_TD_1, 16#26). % 38: CP16Time2A + CP56Time2A                 | Event of protection equipment with time tag
-define(M_EI_NA_1, 16#46). % 70: Initialization Ending

%% Remote control commands without time tag
-define(C_SC_NA_1, 16#2D). % 45: Single command
-define(C_DC_NA_1, 16#2E). % 46: Double command
-define(C_RC_NA_1, 16#2F). % 47: Regulating step command
-define(C_SE_NA_1, 16#30). % 48: Set point command, normalized value
-define(C_SE_NB_1, 16#31). % 49: Set point command, scaled value
-define(C_SE_NC_1, 16#32). % 50: Set point command, short floating point value
-define(C_BO_NA_1, 16#33). % 51: Bit string 32 bit

%% Remote control commands with time tag
-define(C_SC_TA_1, 16#3A). % 58: Single command (time tag)
-define(C_DC_TA_1, 16#3B). % 59: Double command
-define(C_RC_TA_1, 16#3C). % 60: Regulating step command
-define(C_SE_TA_1, 16#3D). % 61: Set point command, normalized value
-define(C_SE_TB_1, 16#3E). % 62: Set point command, scaled value
-define(C_SE_TC_1, 16#3F). % 63: Set point command, short floating point value
-define(C_BO_TA_1, 16#40). % 64: Bit string 32 bit

%% Remote control commands on system information
-define(C_IC_NA_1, 16#64). % 100: Group Request Command
-define(C_CI_NA_1, 16#65). % 101: Counter Interrogation Command
-define(C_CS_NA_1, 16#67). % 103: Clock Synchronization Command

%% Limitations
-define(MAX_FRAME_LIMIT, 32767).
-define(MIN_FRAME_LIMIT, 1).

-define(MAX_COA, 65535).
-define(MIN_COA, 0).
-define(MAX_ORG, 255).
-define(MIN_ORG, 0).

-define(MAX_IOA_BYTES, 3).
-define(MIN_IOA_BYTES, 1).
-define(MAX_COA_BYTES, 2).
-define(MIN_COA_BYTES, 1).
-define(MAX_ORG_BYTES, 1).
-define(MIN_ORG_BYTES, 0).

-define(REMOTE_CONTROL_PRIORITY, 0).
-define(COMMAND_PRIORITY, 1).
-define(UPDATE_PRIORITY, 2).

-define(GLOBAL_GROUP, 0).
-define(START_GROUP, 1).
-define(END_GROUP, 16).

-define(COMPATIBLE_IO_MAPPING, #{
    ?M_SP_TA_1 => ?M_SP_NA_1,  %  2 => 1
    ?M_SP_TB_1 => ?M_SP_NA_1,  % 30 => 1

    ?M_DP_TA_1 => ?M_DP_NA_1,  %  4 => 3
    ?M_DP_TB_1 => ?M_DP_NA_1,  % 31 => 3

    ?M_ST_TA_1 => ?M_ST_NA_1,  %  6 => 5
    ?M_ST_TB_1 => ?M_ST_NA_1,  % 32 => 5

    ?M_BO_TA_1 => ?M_BO_NA_1,  %  8 => 7
    ?M_BO_TB_1 => ?M_BO_NA_1,  % 33 => 7

    ?M_ME_TA_1 => ?M_ME_NA_1,  % 10 => 9
    ?M_ME_TD_1 => ?M_ME_NA_1,  % 34 => 9

    ?M_ME_TB_1 => ?M_ME_NB_1,  % 12 => 11
    ?M_ME_TE_1 => ?M_ME_NB_1,  % 35 => 11

    ?M_ME_TC_1 => ?M_ME_NC_1,  % 14 => 13
    ?M_ME_TF_1 => ?M_ME_NC_1,  % 36 => 13

    ?M_IT_TA_1 => ?M_IT_NA_1,  % 16 => 15
    ?M_IT_TB_1 => ?M_IT_NA_1   % 37 => 15
  }).

-endif.