^IAL^ 
  
************************************************************************
* 
*  INVERSE ASSEMBLER FOR THE 8085 MICROPROCESSOR
* 
*   This source code can be used with the HP 64620S, HP 1630A/D/G
*   HP 1631A/D, HP 1650A, HP 1651A or HP 16510A logic analyzers.
* 
*   INPUT_STATUS consists of the following 8085 signals:
*                              _
*            BIT 3          IO/M
*            BIT 2          HLDA
*            BIT 1          S1
*            BIT 0          S0
* 
*   These signals are clocked in at the end of the bus cycle by the
*   OR'd combination of RD, WR and INTA.
* 
************************************************************************
* 
*                      INITIALIZE
* 
************************************************************************
  
       SEARCH_LIMIT      5
       DEFAULT_WIDTH    20
       MAPPED_WIDTH     20
       LABEL_TITLE      ^8085 Mnemonic^ 
       BASE_TITLE       ^     hex^
  
* 
*          Variables used by the inverse assembler 
* 
  
NEW_ADDRESS     VARIABLE    0   ; ADDRESS TO FETCH
LOW_BYTE        VARIABLE
HIGH_BYTE       VARIABLE
LO_INPUT_ERROR  VARIABLE
LO_INPUT_STATUS VARIABLE
MAP_FLAG        VARIABLE
ADDRESS         VARIABLE
INPUT_MODE      VARIABLE
OPCODE_TEMP     VARIABLE
  
* 
*          Constants used by the inverse assembler
* 

ML16            CONSTANT 00000FFFFH 
  
INPUT_ABS       CONSTANT 0
INPUT_REL       CONSTANT 1
  
STATUS_MASK     CONSTANT 1011B
OPCODE_STATUS   CONSTANT 0011B
  
UNKNOWN         ASCII "unknown" 
MEM_WRITE       ASCII "memory write"
MEM_READ        ASCII "memory read" 
IO_WRITE        ASCII "i/o write" 
IO_READ         ASCII "i/o read"
INT_ACK         ASCII "interrupt ack" 
HALT            ASCII "halt"
  
* 
*  DISPLAY FORMATS
* 
  
HEX4_FMT        FORMAT 16,HEX,4        16 BITS, IN HEX, DISPLAY 4 DIGITS
HEX2_FMT        FORMAT 8,HEX,2         8 BITS, IN HEX, DISPLAY 2 DIGITS 
 
 
************************************************************************
* 
*  Entry Point of Inverse Assembler
* 
************************************************************************
  
        SET INPUT_MODE,INPUT_ABS                NORMALLY, ABSOLUTE READ 
  
        SET RETURN_FLAGS,0           INITIALIZE FLAG TO NOT INSTR. LINE 
  
        LOAD INITIAL_ADDRESS                GET ADDRESS TO DISSASSEMBLE 
        STORE NEW_ADDRESS 
  
        IF INPUT_ERROR <> 0 THEN GOTO DATA_ERROR        BRANCH IF ERROR 
        IF TASK = 3 THEN GOTO ANALYSIS       HP 64620S          
        IF TASK = 4 THEN GOTO ANALYSIS       HP 1630A/D & 1631A/D
        IF TASK = 5 THEN GOTO ANALYSIS       HP 1630G, 1650A/51A & 16510A

ILLG_TASK 
        OUTPUT "Illegal Task Request" 
        ABORT 
  
DATA_ERROR
        OUTPUT "Data error" 
        ABORT 
  
ILLEGAL_OPCODE
        OUTPUT "Illegal Opcode" 
        ABORT 
  
ANALYSIS
       LOAD INPUT_STATUS           GET STATUS OF WHAT WAS READ
       AND STATUS_MASK             MASK OUT HLDA          
       IF 3,0 = OPCODE_STATUS THEN GOTO OPCODE_DECODE     

* 
*  IF ITS NOT AN OPCODE, JUST SHOW THE DATA, FOLLOWED BY THE STATUS 
* 
       
       POSITION REL,2 
       LOAD INPUT_DATA
       OUTPUT ACCUMULATOR,HEX2_FMT
  
MNE_STATUS

* 
*  DISPLAY THE STATUS OF THE MNEMONIC 
* 
* 
*  NOTE, THE STATUS TABLE BELOW IS CONSTRUCTED WITH THE S2 BIT (HLDA) 
*        AS A DONT CARE.  ACTUALLY, BECAUSE OF THE STATE CLOCKING 
*        ARRANGEMENT (INTA or RD or WR), WE WILL NEVER SEE THE CONDITION
*        WHERE HLDA IS HIGH.  
 
       POSITION REL,1 
       LOAD INPUT_STATUS
       AND STATUS_MASK             MASK OUT HLDA
       CASE_OF 3,0
          OUTPUT UNKNOWN           STATUS = 0000B 
          OUTPUT MEM_WRITE         STATUS = 0001B 
          OUTPUT MEM_READ          STATUS = 0010B 
          OUTPUT UNKNOWN           STATUS = 0011B 
          OUTPUT UNKNOWN           STATUS = 0100B 
          OUTPUT MEM_WRITE         STATUS = 0101B 
          OUTPUT MEM_READ          STATUS = 0110B 
          OUTPUT UNKNOWN           STATUS = 0111B 
          OUTPUT HALT              STATUS = 1000B 
          OUTPUT IO_WRITE          STATUS = 1001B 
          OUTPUT IO_READ           STATUS = 1010B 
          OUTPUT INT_ACK           STATUS = 1011B 
          OUTPUT HALT              STATUS = 1100B 
          OUTPUT IO_WRITE          STATUS = 1101B 
          OUTPUT IO_READ           STATUS = 1110B 
          OUTPUT INT_ACK           STATUS = 1111B 
       CASE_END 
       RETURN 
  
  
OPCODE_DECODE 
  
       SET RETURN_FLAGS,1     FLAG AN INSTRUCTION LINE (AS OPPOSED TO DATA) 
       LOAD INPUT_DATA
       CASE_OF 7,6
          GOTO GROUP_1       ;B7-B6=0 
          GOTO GROUP_2              1 
          GOTO GROUP_3              2 
          GOTO GROUP_4              3 
       CASE_END 
 
 
*************************************************************** 
* 
* Group 1 
*      MVI r,exp
*      LXI dr,exp     DAD dr
*      STAX LDAX STA  LDA  SHLD LHLD
*      INR  DCR  INX  DCX 
*      RLC  RRC  RAL  RAR  CMA  STC  CMC  DAA 
*      NOP  RIM  SIM
* 
*************************************************************** 
  
GROUP_1 
       CASE_OF 2,0
         GOTO SPECIAL_1           00XX X000
         GOTO DAD_LXI             00XX X001
         GOTO LOD_STO             00XX X010
         GOTO INX_DCX             00XX X011
         GOTO INR                 00XX X100
         GOTO DCR                 00XX X101
         GOTO MVI                 00XX X110
         GOTO LOGICAL_1           00XX X111
       CASE_END 


*************************************************************** 
* 
* SPECIAL_1 - SPECIAL SYMBOLS 
* 
*************************************************************** 
  
SPECIAL_1 
       IF 3,3 = 1 THEN GOTO ILLEGAL_OPCODE      00XX 1000 
       CASE_OF 5,4
          OUTPUT "NOP"                          0000 0000 
          GOTO ILLEGAL_OPCODE                   0001 0000 
          OUTPUT "RIM"                          0010 0000 
          OUTPUT "SIM"                          0011 0000 
       CASE_END 
       RETURN 


*************************************************************** 
* 
* DAD_LXI 
* 
*************************************************************** 
  
DAD_LXI 
       IF 3,3 = 0 THEN GOTO LXI                 00XX 0001
       OUTPUT "DAD  "                           00XX 1001
       CALL LONG_REG
       RETURN 

LXI 
       OUTPUT "LXI  " 
       CALL LONG_REG
       OUTPUT "," 
       CALL LEXPR_NO_MAP        DONT MAP 16 BIT DATA QUANTITY 
       RETURN 
 
*************************************************************** 
* 
* LOD_STO 
* 
*************************************************************** 
  
LOD_STO 
       IF 5,5 = 0 THEN GOTO LDAX_STAX           000X X010
       CASE_OF 4,3
         OUTPUT "SHLD"                          0010 0010
         OUTPUT "LHLD"                          0010 1010
         OUTPUT "STA "                          0011 0010
         OUTPUT "LDA "                          0011 1010
       CASE_END 
       STORE OPCODE_TEMP        SAVE THE OPCODE ACROSS LEXPR
       POSITION REL,1 
       CALL LEXPR 
       RETURN 
  
LDAX_STAX 
       CASE_OF 3,3                              
         OUTPUT "STAX"                          000X 0010
         OUTPUT "LDAX"                          000X 1010
       CASE_END 
       POSITION REL,1 
       CALL LONG_REG
       RETURN 


*************************************************************** 
* 
* INX_DCX 
* 
*************************************************************** 
  
INX_DCX 
       CASE_OF 3,3
         OUTPUT "INX"                           00XX 0011
         OUTPUT "DCX"                           00XX 1011
       CASE_END 
       POSITION REL,2 
       CALL LONG_REG
       RETURN 
 

*************************************************************** 
* 
* INR 
* 
*************************************************************** 
  
INR 
       OUTPUT "INR  " 
       CALL DREG_NAME 
       RETURN 


*************************************************************** 
* 
* DCR 
* 
*************************************************************** 
  
DCR 
       OUTPUT "DCR  " 
       CALL DREG_NAME 
       RETURN 


*************************************************************** 
* 
* MVI 
* 
*************************************************************** 
  
MVI 
       OUTPUT "MVI  " 
       CALL DREG_NAME 
       OUTPUT "," 
       CALL EXPR
       RETURN 
 

*************************************************************** 
* 
* LOGICAL_1 
* 
*************************************************************** 
  
LOGICAL_1 
       CASE_OF 5,3
         OUTPUT "RLC"                           0000 0111
         OUTPUT "RRC"                           0000 1111
         OUTPUT "RAL"                           0001 0111
         OUTPUT "RAR"                           0001 1111
         OUTPUT "DAA"                           0010 0111
         OUTPUT "CMA"                           0010 1111
         OUTPUT "STC"                           0011 0111
         OUTPUT "CMC"                           0011 1111
       CASE_END 
       POSITION REL,2 
       RETURN 
 

*************************************************************** 
* 
* Group 2 
* 
*************************************************************** 
  
GROUP_2 
        IF 7,0 <> 01110110B THEN GOTO MOVES     BRANCH IF NOT HALT INSTR 
           OUTPUT "HLT" 
           RETURN 

MOVES 
        OUTPUT "MOV  "
        CALL DREG_NAME
        OUTPUT ","
        CALL SREG_NAME
        RETURN
  
 
*************************************************************** 
* 
* Group 3 
* 
*************************************************************** 
  
GROUP_3 
          CASE_OF 5,3 
            OUTPUT "ADD"                        1000 0XXX
            OUTPUT "ADC"                        1000 1XXX
            OUTPUT "SUB"                        1001 0XXX
            OUTPUT "SBB"                        1001 1XXX
            OUTPUT "ANA"                        1010 0XXX
            OUTPUT "XRA"                        1010 1XXX
            OUTPUT "ORA"                        1011 0XXX
            OUTPUT "CMP"                        1011 1XXX
          CASE_END
          POSITION REL,2
          CALL SREG_NAME
          RETURN
  

*************************************************************** 
* 
* Group 4 
* 
*************************************************************** 
  
GROUP_4 
        CASE_OF 2,0 
            GOTO Rcc                            11XX X000
            GOTO POP_RET                        11XX X001
            GOTO Jcc                            11XX X010
            GOTO JMP_IO                         11XX X011
            GOTO Ccc                            11XX X100
            GOTO PUSH_CALL                      11XX X101
            GOTO Immediate                      11XX X110
            GOTO RST                            11XX X111
        CASE_END
        GOTO ILLEGAL_OPCODE 
  

*********************************************************** 
* 
* Rcc 
* 
*********************************************************** 

Rcc 
        OUTPUT "R"
        CALL COND_CODES 
        RETURN
  

*********************************************************** 
* 
* POP_RET Etc.
* 
*********************************************************** 

POP_RET 
        IF 3,3 = 1 THEN GOTO RET_PCHL_SPHL      11XX 1001
        OUTPUT "POP  "                          11XX 0001
        CALL LONG_REG 
        RETURN
  
RET_PCHL_SPHL 
        CASE_OF 5,4 
            OUTPUT "RET  "                      1100 1001
            GOTO   ILLEGAL_OPCODE               1101 1001
            OUTPUT "PCHL "                      1110 1001
            OUTPUT "SPHL "                      1111 1001
        CASE_END
        RETURN
  
 
*********************************************************** 
* 
* Jcc 
* 
*********************************************************** 

Jcc 
        OUTPUT "J"
        CALL COND_CODES 
        POSITION REL,2
        CALL LEXPR              GET 2 BYTES 
        RETURN
 
 
*********************************************************** 
* 
* JMP_IO Etc. 
* 
*********************************************************** 

JMP_IO
        CASE_OF 5,3 
            GOTO JMP                            1100 0011
            GOTO ILLEGAL_OPCODE                 1100 1011
            GOTO OUT_IN                         1101 0011
            GOTO OUT_IN                         1101 1011
            OUTPUT "XTHL "                      1110 0011
            OUTPUT "XCHG "                      1110 1011
            OUTPUT "DI   "                      1111 0011
            OUTPUT "EI   "                      1111 1011
        CASE_END
        RETURN
  
JMP     OUTPUT "JMP  "
        CALL LEXPR
        RETURN
  
OUT_IN
        CASE_OF 3,3 
            OUTPUT "OUT  "                      1101 0011
            OUTPUT "IN   "                      1101 1011
        CASE_END
        CALL EXPR 
        RETURN
  
  
*********************************************************** 
* 
* Ccc 
* 
*********************************************************** 

Ccc 
        OUTPUT "C"
        CALL COND_CODES 
        POSITION REL,2
        CALL LEXPR
        RETURN
  

*********************************************************** 
* 
* PUSH_CALL 
* 
*********************************************************** 

PUSH_CALL 
        IF 3,3 = 0 THEN GOTO PUSH               11XX 0101
        IF 5,3 <> 001 THEN GOTO ILLEGAL_OPCODE 
        OUTPUT "CALL "                          1100 1101
        CALL LEXPR
        RETURN
  
PUSH    OUTPUT "PUSH "
        CALL LONG_REG 
        RETURN
  

*********************************************************** 
* 
* Immediate 
* 
*********************************************************** 

Immediate 
        CASE_OF 5,3 
            OUTPUT "AD"                         1100 0110
            OUTPUT "AC"                         1100 1110
            OUTPUT "SU"                         1101 0110
            OUTPUT "SB"                         1101 1110
            OUTPUT "AN"                         1110 0110
            OUTPUT "XR"                         1110 1110
            OUTPUT "OR"                         1111 0110
            OUTPUT "CP"                         1111 1110
        CASE_END
        OUTPUT "I  "
        CALL EXPR 
        RETURN
 
 
*********************************************************** 
* 
* RST 
* 
*********************************************************** 

RST 
        OUTPUT "RST  "
        CASE_OF 5,3 
            OUTPUT "0"                          1100 0111
            OUTPUT "1"                          1100 1111
            OUTPUT "2"                          1101 0111
            OUTPUT "3"                          1101 1111
            OUTPUT "4"                          1110 0111
            OUTPUT "5"                          1110 1111
            OUTPUT "6"                          1111 0111
            OUTPUT "7"                          1111 1111
        CASE_END
        RETURN
  
  
*********************************************************** 
* 
* COND_CODES - OUTPUT CONDITION CODES 
* 
*********************************************************** 

COND_CODES
        CASE_OF 5,3 
            OUTPUT "NZ"                         XX00 0XXX
            OUTPUT "Z "                         XX00 1XXX
            OUTPUT "NC"                         XX01 0XXX
            OUTPUT "C "                         XX01 1XXX
            OUTPUT "PO"                         XX10 0XXX
            OUTPUT "PE"                         XX10 1XXX
            OUTPUT "P "                         XX11 0XXX
            OUTPUT "M "                         XX11 1XXX
        CASE_END
        RETURN
  
  
*********************************************************** 
* 
*  DREG_NAME - OUTPUT DESTINATION REGISTER NAME 
* 
*********************************************************** 

DREG_NAME 
        CASE_OF 5,3 
            OUTPUT "B"                          XX00 0XXX
            OUTPUT "C"                          XX00 1XXX
            OUTPUT "D"                          XX01 0XXX
            OUTPUT "E"                          XX01 1XXX
            OUTPUT "H"                          XX10 0XXX
            OUTPUT "L"                          XX10 1XXX
            OUTPUT "M"                          XX11 0XXX
            OUTPUT "A"                          XX11 1XXX
        CASE_END
        RETURN
  
  
*********************************************************** 
* 
*  SREG_NAME - OUTPUT SOURCE REGISTER NAME
* 
*********************************************************** 

SREG_NAME 
        CASE_OF 2,0 
            OUTPUT "B"                          XXXX X000
            OUTPUT "C"                          XXXX X001
            OUTPUT "D"                          XXXX X010
            OUTPUT "E"                          XXXX X011
            OUTPUT "H"                          XXXX X100
            OUTPUT "L"                          XXXX X101
            OUTPUT "M"                          XXXX X110
            OUTPUT "A"                          XXXX X111
        CASE_END
        RETURN
 
 
*********************************************************** 
* 
* LONG_REG OUTPUT LONG REGISTER NAME
* 
*********************************************************** 
  
LONG_REG
        CASE_OF 5,4 
            OUTPUT "B"                          XX00 XXXX
            OUTPUT "D"                          XX01 XXXX
            OUTPUT "H"                          XX10 XXXX
            OUTPUT "SP"         POSSIBLY OVERWRITTEN BY PSW CONDITION 
        CASE_END
        IF 7,4 <> 0FH THEN RETURN               1111 XXXX
        POSITION REL,-2 
        OUTPUT "PSW"
        RETURN
  
  
*********************************************************** 
* 
*  LEXPR  OUTPUT 16-BIT HEX VALUE IN NEXT TWO BYTES 
* 
*********************************************************** 

LEXPR 
        SET MAP_FLAG,0          PRESET TO DO ADDRESS MAPPING
        GOTO MAP_SET

LEXPR_NO_MAP
        SET MAP_FLAG,1          PRESET FOR NO MAPPING 

MAP_SET 
        CALL NEXT_BYTE          GET LOW BYTE OF DATA
        STORE LOW_BYTE          SAVE THE LOW ORDER BYTE 
        LOAD INPUT_ERROR        GET ERROR FLAG
        STORE LO_INPUT_ERROR    SAVE ERROR FLAG IN TEMPORARY
        LOAD INPUT_STATUS 
        AND STATUS_MASK         MASK OUT HLDA
        STORE LO_INPUT_STATUS 
  
        CALL NEXT_BYTE          GET HIGH BYTE OF DATA 
        STORE HIGH_BYTE         SAVE THE HIGH ORDER BYTE
  
        ROTATE LEFT,8           MOVE HIGH BYTE TO UPPER 8 BITS
        INCLUSIVE_OR LOW_BYTE   PUT THE 2 BYTES TOGETHER
        AND ML16                ONLY LOWER 16 BITS ARE VALID ADDRESS
        STORE ADDRESS           SAVE THE 16 BIT ADDRESS 
  
        LOAD INPUT_STATUS 
        AND STATUS_MASK         MASK OUT HLDA
        IF 3,0 = OPCODE_STATUS THEN GOTO HI_WAS_OPCODE
        IF LO_INPUT_STATUS = OPCODE_STATUS THEN GOTO NOT_ASSOCIATED 
        IF INPUT_ERROR = 0 THEN GOTO SHOW_CHECK    BRANCH IF NO DATA READ ERROR

HI_WAS_OPCODE 
NOT_ASSOCIATED
           OUTPUT "**"          NO HIGH BYTE FOUND
           SET MAP_FLAG,1       SET TO SKIP ADDRESS MAPPING 
           GOTO CHECK_LOW       CHECK FOR THE LOW ORDER BYTE

SHOW_CHECK
        IF MAP_FLAG = 0 THEN GOTO CHECK_LOW      BRANCH IF STILL MAPPING 
           LOAD HIGH_BYTE               GET UPPER BYTE
           OUTPUT ACCUMULATOR,HEX2_FMT  DISPLAY THE HIGH BYTE 
  
CHECK_LOW 
        IF LO_INPUT_STATUS = OPCODE_STATUS THEN GOTO LO_WAS_OPCODE
        IF LO_INPUT_ERROR = 0 THEN GOTO SHOW_LOW    BRIF NO DATA READ ERROR 

LO_WAS_OPCODE 
           OUTPUT "**"          NO LOW BYTE FOUND 
           RETURN               NO MAPPING, WE ARE FINISHED 

SHOW_LOW
        IF MAP_FLAG = 0 THEN GOTO MAPPER        BRANCH IF MAPPING ALLOWED
           LOAD LOW_BYTE                        GET THE LOW ORDER BYTE
           OUTPUT ACCUMULATOR,HEX2_FMT          DISPLAY THE LOWER BYTE 
           RETURN                               LEAVE 
  
MAPPER
        LOAD ADDRESS            GET THE 16 BIT ADDRESS
        IF_NOT_MAPPED THEN OUTPUT ACCUMULATOR,HEX4_FMT
        RETURN
  
  
*********************************************************** 
* 
*  EXPR  OUTPUT 8-BIT HEX VALUE IN NEXT BYTE
* 
*********************************************************** 

EXPR

        CALL NEXT_BYTE          GET THE BYTE AFTER THE OPCODE 
  
        LOAD INPUT_STATUS       destroys data in accumulator from NEXT_BYTE 
        AND STATUS_MASK         MASK OUT HLDA
        IF 3,0 <> OPCODE_STATUS THEN GOTO EXPR_HEX2   BRANCH IF DATA FOUND 
           OUTPUT "**"          FLAG THE BYTE AS NOT FOUND
           RETURN 

EXPR_HEX2 
        LOAD INPUT_DATA         RELOAD DATA 
        OUTPUT ACCUMULATOR,HEX2_FMT 
        RETURN
  
  
*********************************************************** 
* 
* GET NEXT BYTE FROM ANALYSIS DATA
*  INCREMENTS INPUT_ADDRESS, NEW_ADDRESS AND RETURN_COUNT
* 
*********************************************************** 

NEXT_BYTE 
        INCREMENT NEW_ADDRESS         MOVE AHEAD TO NEXT ADDRESS 

GET_BYTE

* 
*   ENTRY POINT TO READ THE DESIRED BYTE WITHOUT INCREMENTING NEW_ADDRESS
* 
        LOAD INPUT_MODE         SEE WHICH INPUT MODE WE'RE IN 
        CASE_OF 0,0 
          INPUT ABS,NEW_ADDRESS               READ THE DATA
          INPUT REL,NEW_ADDRESS
        CASE_END
        LOAD INPUT_DATA                 SET ACCUMULATOR TO DATA READ
        RETURN
