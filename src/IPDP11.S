"IAL"
************************************************************************
*
*  INVERSE ASSEMBLER FOR THE DEC PDP-11 (UNIBUS)
*
*  For HP 1650/1660/1670, 16500 and 16600/16700 series logic analyzers.
*  Assemble with the HP 10391B Inverse Assembler Development Package:
*
*      ASM IPDP11.S
*
*  Download / convert with IALDOWN (or the 16700 IA Format utility)
*  using "Invasm" field option B (Invasm field, no pop-up).
*
************************************************************************
*
*  ANALYZER LABELS (all Unibus signals are asserted low; set the label
*  polarity to negative "-" in the Format menu so that 1 = asserted):
*
*    ADDR   18 bits   A<17:00>
*    DATA   16 bits   D<15:00>
*    STAT    3 bits   bit 0 = C0
*                     bit 1 = C1
*                     bit 2 = INTR  (connect to ground if not probed)
*
*    C1 C0   0 0  DATI    0 1  DATIP    1 0  DATO    1 1  DATOB
*
*  STATE CLOCK: the negating (trailing) edge of MSYN.  Address, data
*  and C1/C0 are all still valid on the bus at that point for every
*  CPU and DMA transfer.
*
************************************************************************
*
*  HOW IT WORKS
*
*  The Unibus does not say whether a DATI is an instruction fetch or a
*  data read, so the inverse assembler must be synchronized by hand:
*  roll a state that is an instruction fetch to the top of the listing
*  and select the "Invasm" field.  From then on, each decoded
*  instruction looks ahead in the trace:
*
*  - the extension words (immediate, absolute, index) are the reads of
*    the following addresses; they are tagged "operand",
*  - the next instruction fetch is predicted from the instruction:
*    the next sequential address, either branch destination, a jump
*    target taken from an extension word, or (for RTS PC, RTI, RTT and
*    indirect JMP/JSR) the data of the read that fetched the new PC,
*  - a read from the vector area (below VEC_LIMIT) followed by a read
*    of the next word is taken to be an interrupt or trap vector; the
*    new PC is the data of the first of those two reads,
*  - every other cycle in between is tagged as a data cycle.
*
*  The predicted next fetch is tagged and is decoded when the listing
*  reaches it, so the chain continues for as long as the analyzer
*  keeps finding the next fetch within SCANMAX states.
*
************************************************************************

          LABEL_TITLE   ^PDP-11 Mnemonic^
          BASE_TITLE    ^octal^
          DEFAULT_WIDTH 36
          MAX_INSTRUCTION 30000

*
*  Tunables
*
SCANMAX   CONSTANT  32              ; states searched for the next fetch
GUESSMAX  CONSTANT  12              ; same, when recovering a lost chain
VEC_LIMIT CONSTANT  1000Q           ; reads below this may be vectors

*
*  Masks and flags
*
A18       CONSTANT  777777Q         ; Unibus address
W16       CONSTANT  177777Q         ; Unibus data word
PG13      CONSTANT  17777Q          ; offset within an 8KB MMU page
NOMATCH   CONSTANT  0FFFFFFFFH      ; never equal to a bus address
UTAGMASK  CONSTANT  0FFFFH          ; user part of INPUT_TAG
BLANKS    ASCII     "                                    "

*
*  User tags written into the acquisition memory
*
TG_FETCH  CONSTANT  1               ; instruction fetch
TG_OPER   CONSTANT  2               ; extension word of an instruction
TG_DATA   CONSTANT  3               ; data cycle of an instruction
TG_VEC    CONSTANT  4               ; interrupt / trap vector read

*
*  How the next instruction fetch is found (TTYPE)
*
TT_SEQ    CONSTANT  0               ; next sequential instruction
TT_BRANCH CONSTANT  1               ; sequential or BRT
TT_OPWABS CONSTANT  2               ; target = last extension word
TT_OPWREL CONSTANT  3               ; target = PC relative extension word
TT_READ   CONSTANT  4               ; target = data of data read NSKIP
TT_UNKN   CONSTANT  5               ; first read after NSKIP data reads

*
*  Variables
*
OPC       VARIABLE  0               ; opcode being decoded
PCA       VARIABLE  0               ; its bus address
CURSTAT   VARIABLE  0               ; STAT of the state being displayed
TAGCUR    VARIABLE  0               ; user tag of that state
NOPW      VARIABLE  0               ; number of extension words
OPWN      VARIABLE  0               ; extension words found
OPW1      VARIABLE  0               ; first extension word
OPW2      VARIABLE  0               ; second extension word
NXOPW     VARIABLE  0               ; address of next extension word
OPWI      VARIABLE  0               ; extension words printed so far
OPWA      VARIABLE  0               ; address of word being printed
OPWMISS   VARIABLE  0               ; extension word was not found
TTYPE     VARIABLE  0               ; next fetch prediction method
NSKIP     VARIABLE  0               ; data reads before next fetch
BRT       VARIABLE  0               ; branch destination
CAND1     VARIABLE  0               ; next fetch address candidates
CAND2     VARIABLE  0
CMPMASK   VARIABLE  0               ; address bits compared
CANDOK    VARIABLE  0               ; candidates are valid
DREADS    VARIABLE  0               ; data reads seen while scanning
NS        VARIABLE  0               ; scan offset from current state
MS        VARIABLE  0               ; peek offset
CURADDR   VARIABLE  0               ; scanned state address
CURDATA   VARIABLE  0               ; scanned state data
VEC2A     VARIABLE  0               ; address of second vector word
FOUNDV    VARIABLE  0               ; vector pair found
TAGV      VARIABLE  0               ; tag to write
FW        VARIABLE  0               ; extension words of one operand
EAF       VARIABLE  0               ; mode/register field
EAREG     VARIABLE  0               ; register number
TMP       VARIABLE  0
BASE      VARIABLE  0               ; PC value for PC relative operands
CONF      VARIABLE  0               ; 1 = state known to be a fetch
FOUNDF    VARIABLE  0               ; SCAN: 1 found, 2 end of trace
SCLIM     VARIABLE  0               ; SCAN: states to search
VECOK     VARIABLE  0               ; SCAN: may follow a vector fetch
INTRV     VARIABLE  0               ; SCAN: vector seen on an INTR cycle
VP2       VARIABLE  0               ; SCAN: offset of second vector word
LASTW     VARIABLE  0               ; address of the last DATO seen

*
*  Display formats
*
O6        FORMAT    16,OCT,6
P6        FORMAT    18,OCT,6
O3        FORMAT    8,OCT,3
O2        FORMAT    6,OCT,2
O1        FORMAT    3,OCT,1

************************************************************************
*
*  ENTRY
*
************************************************************************
START
          SET       RETURN_FLAGS,0
          LOAD      INITIAL_ADDRESS
          AND       A18
          STORE     PCA
          LOAD      INITIAL_DATA
          AND       W16
          STORE     OPC
          LOAD      INPUT_STATUS
          STORE     CURSTAT
          LOAD      INPUT_TAG
          AND       UTAGMASK
          STORE     TAGCUR
          LOAD      INPUT_TAG
          IF        17,16 <> 0 THEN GOTO SYNCED
          SET       TAGCUR,0                ; not synchronized: raw cycle
          GOTO      SHOWCYC
SYNCED
          LOAD      CURSTAT
          IF        2,2 = 1 THEN GOTO SHOWCYC      ; interrupt vector transfer
          IF        1,1 = 1 THEN GOTO SHOWCYC      ; DATO / DATOB
          SET       CONF,1
          IF        TAGCUR = TG_FETCH THEN GOTO DECODE
*
*  If the state before this one was never disassembled, this is where
*  "Invasm" was selected: decode it whatever it was tagged before.
*  Otherwise a read that no instruction claimed means the chain of
*  fetches was lost; try it as an instruction, and keep it only if its
*  own next fetch is found (see the end of DECODE).
*
          INPUT     REL,-1
          IF        INPUT_ERROR <> 0 THEN GOTO SYNCPT
          LOAD      INPUT_TAG
          IF        17,16 = 0 THEN GOTO SYNCPT
          IF        TAGCUR <> 0 THEN GOTO SHOWCYC
          SET       CONF,0
SYNCPT
          INPUT     REL,0
          TAG_WITH  TG_FETCH

************************************************************************
*
*  DECODE THE INSTRUCTION IN OPC
*
*  Each handler outputs the mnemonic, sets NOPW / TTYPE (and BRT, NSKIP)
*  as needed, calls SCAN to find the extension words and the next
*  instruction fetch, and then outputs the operands.
*
************************************************************************
DECODE
          SET       RETURN_FLAGS,1
          LOAD      CONF                    ; a guess may only trap if it
          STORE     VECOK                   ; is a trap instruction
          SET       NOPW,0
          SET       TTYPE,TT_SEQ
          SET       NSKIP,0
          SET       OPWI,0
          LOAD      OPC
          CASE_OF   15,12
          CALL      GRP0                    ; 00xxxx
          CALL      DBL                     ; 01 MOV
          CALL      DBL                     ; 02 CMP
          CALL      DBL                     ; 03 BIT
          CALL      DBL                     ; 04 BIC
          CALL      DBL                     ; 05 BIS
          CALL      DBL                     ; 06 ADD
          CALL      GRP7                    ; 07 EIS FIS SOB
          CALL      GRP10                   ; 10xxxx
          CALL      DBL                     ; 11 MOVB
          CALL      DBL                     ; 12 CMPB
          CALL      DBL                     ; 13 BITB
          CALL      DBL                     ; 14 BICB
          CALL      DBL                     ; 15 BISB
          CALL      DBL                     ; 16 SUB
          CALL      FPP                     ; 17 floating point
          CASE_END
*
*  A guessed instruction whose next fetch was not found was not an
*  instruction: undo its tags and show it as a bus cycle instead.
*
          IF        CONF = 1 THEN GOTO DEC_CHK
          IF        OPC = 0 THEN SET FOUNDF,0      ; zero data is no HALT
DEC_CHK
          IF        FOUNDF <> 0 THEN RETURN
          CALL      SC_CLR
          IF        CONF = 1 THEN RETURN
          POSITION  ABS,1
          OUTPUT    BLANKS
          INPUT     REL,0
          TAG_WITH  0
          SET       TAGCUR,0
          GOTO      SHOWCYC

************************************************************************
*  Double operand  oSSDD
************************************************************************
DBL
          CASE_OF   15,12
          NOP
          OUTPUT    "MOV"
          OUTPUT    "CMP"
          OUTPUT    "BIT"
          OUTPUT    "BIC"
          OUTPUT    "BIS"
          OUTPUT    "ADD"
          NOP
          NOP
          OUTPUT    "MOVB"
          OUTPUT    "CMPB"
          OUTPUT    "BITB"
          OUTPUT    "BICB"
          OUTPUT    "BISB"
          OUTPUT    "SUB"
          CASE_END
          LOAD      OPC
          ROTATE    RIGHT,6
          CALL      FWORDS
          LOAD      FW
          STORE     NOPW
          LOAD      OPC
          CALL      FWORDS
          LOAD      NOPW
          ADD       FW
          STORE     NOPW
*
*  An instruction that writes the PC changes the flow of control.
*
          LOAD      OPC
          IF        5,0 <> 7 THEN GOTO DBL_SCAN
          IF        14,12 = 2 THEN GOTO DBL_SCAN   ; CMP(B) does not write
          IF        14,12 = 3 THEN GOTO DBL_SCAN   ; BIT(B) does not write
          ROTATE    RIGHT,6
          CALL      SRDS                    ; NSKIP = source data reads
          SET       TTYPE,TT_UNKN
          LOAD      OPC
          IF        14,12 <> 1 THEN GOTO DBL_SCAN  ; ADD x,PC etc.
          IF        11,6 = 27Q THEN SET TTYPE,TT_OPWABS ; MOV #x,PC
          IF        11,6 = 27Q THEN GOTO DBL_SCAN
          IF        NSKIP <> 0 THEN SET TTYPE,TT_READ   ; MOV (SP)+,PC etc.
DBL_SCAN
          CALL      SCAN
          POSITION  ABS,9
          LOAD      OPC
          ROTATE    RIGHT,6
          CALL      EA
          OUTPUT    ","
          LOAD      OPC
          GOTO      EA

************************************************************************
*  Group 00xxxx
************************************************************************
GRP0
          CASE_OF   11,8
          GOTO      G00                     ; 0000xx-0003xx
          GOTO      BR0                     ; BR
          GOTO      BR0                     ; BNE
          GOTO      BR0                     ; BEQ
          GOTO      BR0                     ; BGE
          GOTO      BR0                     ; BLT
          GOTO      BR0                     ; BGT
          GOTO      BR0                     ; BLE
          GOTO      JSR                     ; 004RDD
          GOTO      JSR
          GOTO      SOP50                   ; CLR COM INC DEC
          GOTO      SOP54                   ; NEG ADC SBC TST
          GOTO      SOP60                   ; ROR ROL ASR ASL
          GOTO      SOP64                   ; MARK MFPI MTPI SXT
          GOTO      SOP70                   ; CSM - TSTSET WRTLCK
          GOTO      ILLEGAL                 ; 0074xx-0077xx
          CASE_END

G00
          CASE_OF   7,6
          GOTO      G000                    ; 00000x
          GOTO      JMP                     ; 0001DD
          GOTO      G002                    ; 0002xx
          GOTO      SWAB                    ; 0003DD
          CASE_END

G000
          IF        5,3 <> 0 THEN GOTO ILLEGAL
          CASE_OF   2,0
          OUTPUT    "HALT"
          OUTPUT    "WAIT"
          GOTO      RTI
          GOTO      BPT
          GOTO      IOT
          OUTPUT    "RESET"
          GOTO      RTT
          OUTPUT    "MFPT"
          CASE_END
          GOTO      NOOPND

BPT
          OUTPUT    "BPT"
          SET       VECOK,1
          GOTO      NOOPND
IOT
          OUTPUT    "IOT"
          SET       VECOK,1
          GOTO      NOOPND
RTI
          OUTPUT    "RTI"
          GOTO      RTXX
RTT
          OUTPUT    "RTT"
RTXX
          SET       TTYPE,TT_READ           ; new PC is the first pop
          SET       NSKIP,1
          GOTO      NOOPND

G002
          CASE_OF   5,3
          GOTO      RTS                     ; 00020R
          GOTO      ILLEGAL                 ; 00021x
          GOTO      ILLEGAL                 ; 00022x
          GOTO      SPL                     ; 00023N
          GOTO      CCOPS                   ; 00024x
          GOTO      CCOPS                   ; 00025x
          GOTO      CCOPS                   ; 00026x
          GOTO      CCOPS                   ; 00027x
          CASE_END

RTS
          OUTPUT    "RTS"
          SET       TTYPE,TT_UNKN           ; RTS Rn: PC = Rn, then pop
          SET       NSKIP,1
          LOAD      OPC
          IF        2,0 = 7 THEN SET TTYPE,TT_READ ; RTS PC: PC = pop
          CALL      SCAN
          POSITION  ABS,9
          LOAD      OPC
          GOTO      REG20

SPL
          OUTPUT    "SPL"
          CALL      SCAN
          POSITION  ABS,9
          LOAD      OPC
          OUTPUT    ACCUMULATOR,O1
          RETURN

CCOPS
          IF        3,0 = 0 THEN GOTO CC_NOP
          IF        3,0 = 17Q THEN GOTO CC_ALL
          CASE_OF   4,4
          OUTPUT    "CL"
          OUTPUT    "SE"
          CASE_END
          IF        3,3 = 1 THEN OUTPUT "N"
          IF        2,2 = 1 THEN OUTPUT "Z"
          IF        1,1 = 1 THEN OUTPUT "V"
          IF        0,0 = 1 THEN OUTPUT "C"
          GOTO      NOOPND
CC_NOP
          OUTPUT    "NOP"
          GOTO      NOOPND
CC_ALL
          CASE_OF   4,4
          OUTPUT    "CCC"
          OUTPUT    "SCC"
          CASE_END
          GOTO      NOOPND

SWAB
          OUTPUT    "SWAB"
          GOTO      SOP

JMP
          OUTPUT    "JMP"
          CALL      JTGT
          CALL      SCAN
          POSITION  ABS,9
          LOAD      OPC
          GOTO      EA

JSR
          OUTPUT    "JSR"
          CALL      JTGT
          CALL      SCAN
          POSITION  ABS,9
          CALL      REG86
          OUTPUT    ","
          LOAD      OPC
          GOTO      EA

*
*  JTGT - how to find the target of JMP / JSR
*
JTGT
          LOAD      OPC
          CALL      FWORDS
          LOAD      FW
          STORE     NOPW
          LOAD      OPC
          SET       TTYPE,TT_UNKN           ; (Rn) (Rn)+ -(Rn) X(Rn)
          IF        5,0 = 37Q THEN GOTO JT_ABS     ; @#X
          IF        5,0 = 67Q THEN GOTO JT_REL     ; X   (PC relative)
          IF        5,3 = 1 THEN RETURN            ; (Rn): no read
          IF        3,3 = 1 THEN GOTO JT_RD        ; deferred modes 3 5 7
          RETURN
JT_ABS
          SET       TTYPE,TT_OPWABS
          RETURN
JT_REL
          SET       TTYPE,TT_OPWREL
          RETURN
JT_RD
          SET       TTYPE,TT_READ           ; new PC = pointer read
          SET       NSKIP,1
          RETURN

BR0
          CASE_OF   10,8
          NOP
          OUTPUT    "BR"
          OUTPUT    "BNE"
          OUTPUT    "BEQ"
          OUTPUT    "BGE"
          OUTPUT    "BLT"
          OUTPUT    "BGT"
          OUTPUT    "BLE"
          CASE_END
          GOTO      BRANCH

SOP50
          CASE_OF   7,6
          OUTPUT    "CLR"
          OUTPUT    "COM"
          OUTPUT    "INC"
          OUTPUT    "DEC"
          CASE_END
          GOTO      SOPB
SOP54
          CASE_OF   7,6
          OUTPUT    "NEG"
          OUTPUT    "ADC"
          OUTPUT    "SBC"
          OUTPUT    "TST"
          CASE_END
          GOTO      SOPB
SOP60
          CASE_OF   7,6
          OUTPUT    "ROR"
          OUTPUT    "ROL"
          OUTPUT    "ASR"
          OUTPUT    "ASL"
          CASE_END
SOPB
          LOAD      OPC
          IF        15,15 = 1 THEN OUTPUT "B"
          GOTO      SOP
SOP64
          CASE_OF   7,6
          GOTO      MARK
          OUTPUT    "MFPI"
          OUTPUT    "MTPI"
          OUTPUT    "SXT"
          CASE_END
          GOTO      SOP
SOP70
          CASE_OF   7,6
          OUTPUT    "CSM"
          GOTO      ILLEGAL
          OUTPUT    "TSTSET"
          OUTPUT    "WRTLCK"
          CASE_END
          GOTO      SOP

MARK
          OUTPUT    "MARK"
          SET       TTYPE,TT_UNKN           ; PC = R5, then pop R5
          SET       NSKIP,1
          CALL      SCAN
          POSITION  ABS,9
          LOAD      OPC
          OUTPUT    ACCUMULATOR,O2
          RETURN

************************************************************************
*  Group 10xxxx
************************************************************************
GRP10
          CASE_OF   11,8
          GOTO      BR10                    ; BPL
          GOTO      BR10                    ; BMI
          GOTO      BR10                    ; BHI
          GOTO      BR10                    ; BLOS
          GOTO      BR10                    ; BVC
          GOTO      BR10                    ; BVS
          GOTO      BR10                    ; BCC
          GOTO      BR10                    ; BCS
          GOTO      EMT                     ; 1040xx-1043xx
          GOTO      TRAP                    ; 1044xx-1047xx
          GOTO      SOP50                   ; CLRB COMB INCB DECB
          GOTO      SOP54                   ; NEGB ADCB SBCB TSTB
          GOTO      SOP60                   ; RORB ROLB ASRB ASLB
          GOTO      SOPB64                  ; MTPS MFPD MTPD MFPS
          GOTO      ILLEGAL
          GOTO      ILLEGAL
          CASE_END

BR10
          CASE_OF   10,8
          OUTPUT    "BPL"
          OUTPUT    "BMI"
          OUTPUT    "BHI"
          OUTPUT    "BLOS"
          OUTPUT    "BVC"
          OUTPUT    "BVS"
          OUTPUT    "BCC"
          OUTPUT    "BCS"
          CASE_END
          GOTO      BRANCH

EMT
          OUTPUT    "EMT"
          GOTO      EMTN
TRAP
          OUTPUT    "TRAP"
EMTN
          SET       VECOK,1
          CALL      SCAN
          POSITION  ABS,9
          LOAD      OPC
          OUTPUT    ACCUMULATOR,O3
          RETURN

SOPB64
          CASE_OF   7,6
          OUTPUT    "MTPS"
          OUTPUT    "MFPD"
          OUTPUT    "MTPD"
          OUTPUT    "MFPS"
          CASE_END
          GOTO      SOP

************************************************************************
*  Group 07xxxx  EIS, FIS, SOB
************************************************************************
GRP7
          CASE_OF   11,9
          GOTO      EIS_MUL                 ; 070RSS
          GOTO      EIS_DIV                 ; 071RSS
          GOTO      EIS_ASH                 ; 072RSS
          GOTO      EIS_ASHC                ; 073RSS
          GOTO      EIS_XOR                 ; 074RDD
          GOTO      FIS                     ; 07500R-07503R
          GOTO      ILLEGAL                 ; 076xxx (CIS)
          GOTO      SOB                     ; 077RNN
          CASE_END

EIS_MUL
          OUTPUT    "MUL"
          GOTO      EIS_SR
EIS_DIV
          OUTPUT    "DIV"
          GOTO      EIS_SR
EIS_ASH
          OUTPUT    "ASH"
          GOTO      EIS_SR
EIS_ASHC
          OUTPUT    "ASHC"
EIS_SR
          LOAD      OPC
          CALL      FWORDS
          LOAD      FW
          STORE     NOPW
          CALL      SCAN
          POSITION  ABS,9
          LOAD      OPC
          CALL      EA
          OUTPUT    ","
          GOTO      REG86

EIS_XOR
          OUTPUT    "XOR"
          LOAD      OPC
          CALL      FWORDS
          LOAD      FW
          STORE     NOPW
          CALL      SCAN
          POSITION  ABS,9
          CALL      REG86
          OUTPUT    ","
          LOAD      OPC
          GOTO      EA

FIS
          IF        8,5 <> 0 THEN GOTO ILLEGAL
          CASE_OF   4,3
          OUTPUT    "FADD"
          OUTPUT    "FSUB"
          OUTPUT    "FMUL"
          OUTPUT    "FDIV"
          CASE_END
          CALL      SCAN
          POSITION  ABS,9
          LOAD      OPC
          GOTO      REG20

SOB
          OUTPUT    "SOB"
          LOAD      PCA
          ADD       2
          STORE     BASE
          LOAD      OPC
          AND       77Q
          STORE     TMP
          ADD       TMP
          TWOS_COMPLEMENT
          AND       W16
          CALL      PCREL
          STORE     BRT
          SET       TTYPE,TT_BRANCH
          CALL      SCAN
          POSITION  ABS,9
          CALL      REG86
          OUTPUT    ","
          LOAD      BRT
          GOTO      ADDROUT

************************************************************************
*  Group 17xxxx  FP11 floating point
************************************************************************
FPP
          CASE_OF   11,8
          GOTO      FP0                     ; 1700xx-1703xx
          GOTO      FP1                     ; 1704xx-1707xx
          OUTPUT    "MULF"
          OUTPUT    "MODF"
          OUTPUT    "ADDF"
          OUTPUT    "LDF"
          OUTPUT    "SUBF"
          OUTPUT    "CMPF"
          OUTPUT    "STF"
          OUTPUT    "DIVF"
          OUTPUT    "STEXP"
          OUTPUT    "STCFI"
          OUTPUT    "STCFD"
          OUTPUT    "LDEXP"
          OUTPUT    "LDCIF"
          OUTPUT    "LDCDF"
          CASE_END
          LOAD      OPC
          CALL      FWORDS
          LOAD      FW
          STORE     NOPW
          CALL      SCAN
          POSITION  ABS,9
          LOAD      OPC
          CASE_OF   11,8
          NOP
          NOP
          GOTO      FP_FSAC                 ; MULF  fsrc,AC
          GOTO      FP_FSAC                 ; MODF
          GOTO      FP_FSAC                 ; ADDF
          GOTO      FP_FSAC                 ; LDF
          GOTO      FP_FSAC                 ; SUBF
          GOTO      FP_FSAC                 ; CMPF
          GOTO      FP_ACFD                 ; STF   AC,fdst
          GOTO      FP_FSAC                 ; DIVF
          GOTO      FP_ACD                  ; STEXP AC,dst
          GOTO      FP_ACD                  ; STCFI AC,dst
          GOTO      FP_ACFD                 ; STCFD AC,fdst
          GOTO      FP_SAC                  ; LDEXP src,AC
          GOTO      FP_SAC                  ; LDCIF src,AC
          GOTO      FP_FSAC                 ; LDCDF fsrc,AC
          CASE_END
          RETURN

FP_FSAC
          CALL      FEA
          OUTPUT    ","
          GOTO      FPAC
FP_SAC
          CALL      EA
          OUTPUT    ","
          GOTO      FPAC
FP_ACFD
          CALL      FPAC
          OUTPUT    ","
          LOAD      OPC
          GOTO      FEA
FP_ACD
          CALL      FPAC
          OUTPUT    ","
          LOAD      OPC
          GOTO      EA

FP0
          CASE_OF   7,6
          GOTO      FP00
          OUTPUT    "LDFPS"
          OUTPUT    "STFPS"
          OUTPUT    "STST"
          CASE_END
          GOTO      SOP

FP00
          IF        5,4 <> 0 THEN GOTO ILLEGAL
          CASE_OF   3,0
          OUTPUT    "CFCC"                  ; 170000
          OUTPUT    "SETF"                  ; 170001
          OUTPUT    "SETI"                  ; 170002
          GOTO      ILLEGAL                 ; 170003
          GOTO      ILLEGAL                 ; 170004
          GOTO      ILLEGAL                 ; 170005
          GOTO      ILLEGAL                 ; 170006
          GOTO      ILLEGAL                 ; 170007
          GOTO      ILLEGAL                 ; 170010
          OUTPUT    "SETD"                  ; 170011
          OUTPUT    "SETL"                  ; 170012
          GOTO      ILLEGAL                 ; 170013
          GOTO      ILLEGAL                 ; 170014
          GOTO      ILLEGAL                 ; 170015
          GOTO      ILLEGAL                 ; 170016
          GOTO      ILLEGAL                 ; 170017
          CASE_END
          GOTO      NOOPND

FP1
          CASE_OF   7,6
          OUTPUT    "CLRF"
          OUTPUT    "TSTF"
          OUTPUT    "ABSF"
          OUTPUT    "NEGF"
          CASE_END
          LOAD      OPC
          CALL      FWORDS
          LOAD      FW
          STORE     NOPW
          CALL      SCAN
          POSITION  ABS,9
          LOAD      OPC
          GOTO      FEA

*
*  FPAC - floating accumulator in bits 7-6
*
FPAC
          LOAD      OPC
          ROTATE    RIGHT,6
          AND       3
          OUTPUT    "AC"
          OUTPUT    ACCUMULATOR,O1
          RETURN

*
*  FEA - floating point operand: mode 0 is a floating accumulator
*
FEA
          IF        5,3 <> 0 THEN GOTO EA
          AND       7
          OUTPUT    "AC"
          OUTPUT    ACCUMULATOR,O1
          RETURN

************************************************************************
*  Common tails
************************************************************************
*
*  SOP - single operand in bits 5-0 (mnemonic already output)
*
SOP
          LOAD      OPC
          CALL      FWORDS
          LOAD      FW
          STORE     NOPW
          LOAD      OPC
          IF        5,0 = 7 THEN SET TTYPE,TT_UNKN ; e.g. CLR PC
          CALL      SCAN
          POSITION  ABS,9
          LOAD      OPC
          GOTO      EA

*
*  NOOPND - no operands
*
NOOPND
          CALL      SCAN
          RETURN

*
*  BRANCH - 8 bit word offset in OPC (mnemonic already output)
*
BRANCH
          LOAD      PCA
          ADD       2
          STORE     BASE
          LOAD      OPC
          AND       377Q
          IF        7,7 = 1 THEN INCLUSIVE_OR 0FFFFFF00H
          STORE     TMP
          ADD       TMP
          AND       W16
          CALL      PCREL
          STORE     BRT
          SET       TTYPE,TT_BRANCH
          CALL      SCAN
          POSITION  ABS,9
          LOAD      BRT
ADDROUT
          IF_NOT_MAPPED THEN OUTPUT ACCUMULATOR,P6
          RETURN

*
*  PCREL - accumulator = BASE + 16 bit displacement in the accumulator.
*
*  Below the I/O page the sum is a (sign extended) bus address.  Code
*  running in the I/O page (e.g. boot ROMs) uses 16 bit virtual addresses
*  that map 160000-177777 to 760000-777777.
*
PCREL
          AND       W16
          IF        15,15 = 1 THEN INCLUSIVE_OR 0FFFF0000H
          ADD       BASE
          STORE     TMP
          LOAD      BASE
          IF        17,13 = 37Q THEN GOTO PCR_IO
          LOAD      TMP
          AND       A18
          RETURN
PCR_IO
          LOAD      TMP
          AND       W16
          IF        15,13 = 7 THEN INCLUSIVE_OR 600000Q
          RETURN

*
*  ILLEGAL - not an instruction on any Unibus PDP-11
*
ILLEGAL
          OUTPUT    ".WORD"
          SET       NOPW,0
          SET       TTYPE,TT_SEQ
          CALL      SCAN
          IF        CONF = 0 THEN SET FOUNDF,0
          POSITION  ABS,9
          LOAD      OPC
          OUTPUT    ACCUMULATOR,O6
          RETURN

************************************************************************
*
*  SCAN - look ahead in the trace for the extension words and the next
*  instruction fetch, and tag every state up to that fetch.
*
************************************************************************
SCAN
          SET       FOUNDF,0
          SET       NS,0
          LOAD      SCANMAX
          IF        CONF = 0 THEN LOAD GUESSMAX
          STORE     SCLIM
          SET       DREADS,0
          SET       OPWN,0
          LOAD      NOMATCH
          STORE     CAND2
          STORE     VEC2A
          STORE     INTRV
          LOAD      A18
          STORE     CMPMASK
          LOAD      PCA
          ADD       2
          AND       A18
          STORE     NXOPW
          LOAD      NOPW                    ; sequential next fetch
          ADD       NOPW
          ADD       NXOPW
          AND       A18
          STORE     CAND1
          SET       CANDOK,1
          IF        TTYPE = TT_SEQ THEN GOTO SC_LOOP
          LOAD      BRT
          STORE     CAND2
          IF        TTYPE = TT_BRANCH THEN GOTO SC_LOOP
          LOAD      NOMATCH                 ; target not known yet
          STORE     CAND1
          STORE     CAND2
          SET       CANDOK,0

SC_LOOP
          INCREMENT NS
          IF        NS > SCLIM THEN RETURN
          INPUT     REL,NS
          IF        INPUT_ERROR <> 0 THEN SET FOUNDF,2
          IF        INPUT_ERROR <> 0 THEN RETURN
          LOAD      INPUT_DATA
          AND       W16
          STORE     CURDATA
          LOAD      INPUT_ADDRESS
          AND       A18
          STORE     CURADDR
          LOAD      INPUT_STATUS
          IF        2,2 = 1 THEN GOTO SC_INTR      ; INTR transfer
          IF        1,1 = 1 THEN GOTO SC_DATA      ; DATO / DATOB
          IF        OPWN >= NOPW THEN GOTO SC_FETCH
          LOAD      CURADDR
          IF        31,0 <> NXOPW THEN GOTO SC_DREAD
*
*  Extension word
*
          LOAD      CURDATA
          IF        OPWN = 0 THEN STORE OPW1
          IF        OPWN = 1 THEN STORE OPW2
          INCREMENT OPWN
          LOAD      NXOPW
          ADD       2
          AND       A18
          STORE     NXOPW
          SET       TAGV,TG_OPER
          CALL      SC_TAG
          IF        OPWN < NOPW THEN GOTO SC_LOOP
          IF        TTYPE = TT_OPWABS THEN GOTO SC_OABS
          IF        TTYPE <> TT_OPWREL THEN GOTO SC_LOOP
          LOAD      CURADDR                 ; X(PC): X + address + 2
          ADD       2
          STORE     BASE
          LOAD      CURDATA
          CALL      PCREL
          STORE     CAND1
          SET       CANDOK,1
          GOTO      SC_LOOP
SC_OABS
          LOAD      CURDATA                 ; @#X or #X: virtual address
          STORE     CAND1
          LOAD      PG13
          STORE     CMPMASK
          SET       CANDOK,1
          GOTO      SC_LOOP
*
*  A read after all extension words: is it the next fetch?
*
SC_FETCH
          IF        CANDOK = 0 THEN GOTO SC_DREAD
          LOAD      CURADDR
          EXCLUSIVE_OR CAND1
          AND       CMPMASK
          IF        31,0 = 0 THEN GOTO SC_FOUND
          LOAD      CURADDR
          EXCLUSIVE_OR CAND2
          AND       CMPMASK
          IF        31,0 = 0 THEN GOTO SC_FOUND
*
*  Some other read: vector fetch or data read
*
SC_DREAD
          LOAD      CURADDR
          IF        31,0 = VEC2A THEN GOTO SC_VEC
          IF        VECOK = 0 THEN GOTO SC_DR2
          IF        31,0 >= VEC_LIMIT THEN GOTO SC_DR2
          IF        0,0 = 1 THEN GOTO SC_DR2
          CALL      SC_PEEK                 ; vector pair V, V+2 ...
          IF        FOUNDV = 0 THEN GOTO SC_DR2
          LOAD      CURADDR
          IF        31,0 = INTRV THEN GOTO SC_ISVEC  ; ... announced by INTR
          CALL      SC_PUSH                 ; ... or next to two pushes
          IF        FOUNDV = 0 THEN GOTO SC_DR2
SC_ISVEC
          LOAD      CURDATA                 ; new PC from the vector
          STORE     CAND1
          LOAD      NOMATCH
          STORE     CAND2
          LOAD      PG13
          STORE     CMPMASK
          SET       CANDOK,1
          SET       TTYPE,TT_OPWABS
          LOAD      OPWN                    ; no more extension words
          STORE     NOPW
          LOAD      CURADDR
          ADD       2
          STORE     VEC2A
SC_VEC
          SET       TAGV,TG_VEC
          CALL      SC_TAG
          GOTO      SC_LOOP
SC_DR2
          IF        OPWN < NOPW THEN GOTO SC_DR3
          IF        TTYPE <> TT_UNKN THEN GOTO SC_DR3
          LOAD      DREADS
          IF        31,0 < NSKIP THEN GOTO SC_DR3
          CALL      SC_NEAR                 ; a fetch at X is followed
          IF        FOUNDV = 1 THEN GOTO SC_FOUND  ; by a read of X+2
          LOAD      CURDATA                 ; ... unless it transfers
          CALL      CTLXFER                 ; control
          IF        FOUNDV = 1 THEN GOTO SC_FOUND
SC_DR3
          INCREMENT DREADS
          IF        TTYPE <> TT_READ THEN GOTO SC_DATA
          IF        DREADS <> NSKIP THEN GOTO SC_DATA
          LOAD      CURDATA                 ; this read fetched the new PC
          STORE     CAND1
          LOAD      PG13
          STORE     CMPMASK
          SET       CANDOK,1
SC_INTR
          LOAD      CURDATA                 ; device vector on the data lines
          STORE     INTRV
SC_DATA
          SET       TAGV,TG_DATA
          CALL      SC_TAG
          GOTO      SC_LOOP
SC_FOUND
          SET       TAGV,TG_FETCH
          CALL      SC_TAG
          SET       FOUNDF,1
          RETURN

SC_TAG
          INPUT     REL,NS
          TAG_WITH  TAGV
          RETURN

*
*  SC_CLR - remove the tags the last SCAN wrote (but keep the extension
*           words of an instruction that is known to be one)
*
SC_CLR
          SET       MS,0
SCC_LOOP
          INCREMENT MS
          IF        MS > NS THEN RETURN
          IF        MS > SCANMAX THEN RETURN
          INPUT     REL,MS
          IF        INPUT_ERROR <> 0 THEN RETURN
          IF        CONF = 0 THEN GOTO SCC_ZAP
          LOAD      INPUT_TAG
          AND       UTAGMASK
          IF        31,0 = TG_OPER THEN GOTO SCC_LOOP
SCC_ZAP
          TAG_WITH  0
          GOTO      SCC_LOOP

*
*  SC_NEAR - is there a read of CURADDR+2 soon after state NS ?
*
SC_NEAR
          SET       FOUNDV,0
          LOAD      NS
          STORE     MS
          LOAD      CURADDR
          ADD       2
          STORE     TMP
SN_LOOP
          INCREMENT MS
          LOAD      MS
          SUBTRACT  NS
          IF        31,0 > 8 THEN RETURN
          INPUT     REL,MS
          IF        INPUT_ERROR <> 0 THEN RETURN
          LOAD      INPUT_STATUS
          IF        2,2 = 1 THEN GOTO SN_LOOP
          IF        1,1 = 1 THEN GOTO SN_LOOP
          LOAD      INPUT_ADDRESS
          AND       A18
          IF        31,0 <> TMP THEN GOTO SN_LOOP
          SET       FOUNDV,1
          RETURN

*
*  CTLXFER - FOUNDV = 1 if the opcode in the accumulator is a trap,
*            branch, JMP, JSR, RTS, RTI or RTT
*
CTLXFER
          SET       FOUNDV,1
          IF        15,8 = 210Q THEN RETURN        ; EMT
          IF        15,8 = 211Q THEN RETURN        ; TRAP
          IF        15,11 = 20Q THEN RETURN        ; BPL ... BCS
          IF        15,9 = 4 THEN RETURN           ; JSR
          IF        15,11 <> 0 THEN GOTO CTX_NO
          IF        10,8 <> 0 THEN RETURN          ; BR ... BLE
          IF        7,6 = 1 THEN RETURN            ; JMP
          IF        7,3 = 20Q THEN RETURN          ; RTS
          IF        7,0 = 2 THEN RETURN            ; RTI
          IF        7,0 = 3 THEN RETURN            ; BPT
          IF        7,0 = 4 THEN RETURN            ; IOT
          IF        7,0 = 6 THEN RETURN            ; RTT
CTX_NO
          SET       FOUNDV,0
          RETURN

*
*  SC_PEEK - is the next read after state NS at address CURADDR+2 ?
*
SC_PEEK
          SET       FOUNDV,0
          LOAD      NS
          STORE     MS
          LOAD      CURADDR
          ADD       2
          STORE     TMP
SP_LOOP
          INCREMENT MS
          LOAD      MS
          SUBTRACT  NS
          IF        31,0 > 4 THEN RETURN
          INPUT     REL,MS
          IF        INPUT_ERROR <> 0 THEN RETURN
          LOAD      INPUT_STATUS
          IF        2,2 = 1 THEN GOTO SP_LOOP
          IF        1,1 = 1 THEN GOTO SP_LOOP
          LOAD      INPUT_ADDRESS
          AND       A18
          IF        31,0 <> TMP THEN RETURN
          LOAD      MS
          STORE     VP2
          SET       FOUNDV,1
          RETURN

*
*  SC_PUSH - an interrupt or trap pushes PS and PC just before or just
*            after reading the vector: look for two word writes to
*            descending addresses around the vector pair (NS .. VP2).
*
SC_PUSH
          SET       FOUNDV,0
          LOAD      NOMATCH
          STORE     LASTW
          LOAD      NS
          SUBTRACT  3
          STORE     MS
          IF        31,31 = 1 THEN SET MS,0        ; not before the
          IF        MS = 0 THEN SET MS,1           ; instruction itself
          LOAD      VP2
          ADD       3
          STORE     TMP
SPU_LOOP
          IF        MS > TMP THEN RETURN
          INPUT     REL,MS
          INCREMENT MS
          IF        INPUT_ERROR <> 0 THEN RETURN
          LOAD      INPUT_STATUS
          IF        2,0 <> 2 THEN GOTO SPU_LOOP    ; DATO only
          LOAD      LASTW
          SUBTRACT  2
          STORE     LASTW
          LOAD      INPUT_ADDRESS
          AND       A18
          IF        31,0 = LASTW THEN GOTO SPU_YES
          STORE     LASTW
          GOTO      SPU_LOOP
SPU_YES
          SET       FOUNDV,1
          RETURN

************************************************************************
*
*  OPERAND OUTPUT
*
************************************************************************
*
*  FWORDS - FW = extension words needed by the operand in bits 5-0
*
FWORDS
          SET       FW,0
          IF        5,4 = 3 THEN GOTO FW_1         ; modes 6 7
          IF        5,4 <> 1 THEN RETURN           ; modes 0 1 4 5
          IF        2,0 <> 7 THEN RETURN           ; modes 2 3, not PC
FW_1
          SET       FW,1
          RETURN

*
*  SRDS - NSKIP = data reads made to fetch the source in bits 5-0
*
SRDS
          STORE     TMP
          CASE_OF   5,3
          SET       NSKIP,0
          SET       NSKIP,1
          SET       NSKIP,1
          SET       NSKIP,2
          SET       NSKIP,1
          SET       NSKIP,2
          SET       NSKIP,1
          SET       NSKIP,2
          CASE_END
          LOAD      TMP
          IF        2,0 <> 7 THEN RETURN
          IF        5,4 <> 1 THEN RETURN
          DECREMENT NSKIP                   ; #X and @#X
          RETURN

*
*  EA - output the operand in bits 5-0 of the accumulator
*
EA
          AND       77Q
          STORE     EAF
          AND       7
          STORE     EAREG
          LOAD      EAF
          CASE_OF   5,3
          GOTO      REGNAME                 ; Rn
          GOTO      EA_DEF                  ; (Rn)
          GOTO      EA_AINC                 ; (Rn)+
          GOTO      EA_AINCD                ; @(Rn)+
          GOTO      EA_ADEC                 ; -(Rn)
          GOTO      EA_ADECD                ; @-(Rn)
          GOTO      EA_IDX                  ; X(Rn)
          GOTO      EA_IDXD                 ; @X(Rn)
          CASE_END
EA_DEF
          OUTPUT    "("
          CALL      REGNAME
          OUTPUT    ")"
          RETURN
EA_AINCD
          OUTPUT    "@"
EA_AINC
          IF        EAREG = 7 THEN GOTO EA_IMM
          OUTPUT    "("
          CALL      REGNAME
          OUTPUT    ")+"
          RETURN
EA_IMM
          OUTPUT    "#"
          CALL      NEXTOPW
          IF        OPWMISS = 1 THEN GOTO STARS
          OUTPUT    ACCUMULATOR,O6
          RETURN
EA_ADECD
          OUTPUT    "@"
EA_ADEC
          OUTPUT    "-("
          CALL      REGNAME
          OUTPUT    ")"
          RETURN
EA_IDXD
          OUTPUT    "@"
EA_IDX
          CALL      NEXTOPW
          IF        OPWMISS = 1 THEN GOTO EA_IDXM
          IF        EAREG = 7 THEN GOTO EA_REL
          OUTPUT    ACCUMULATOR,O6
          GOTO      EA_IDXR
EA_IDXM
          OUTPUT    "******"
          IF        EAREG = 7 THEN RETURN
EA_IDXR
          OUTPUT    "("
          CALL      REGNAME
          OUTPUT    ")"
          RETURN
EA_REL
          STORE     TMP                     ; X + address of X + 2
          LOAD      OPWA
          ADD       2
          STORE     BASE
          LOAD      TMP
          CALL      PCREL
          GOTO      ADDROUT
STARS
          OUTPUT    "******"
          RETURN

*
*  NEXTOPW - accumulator = next extension word, OPWA = its address,
*            OPWMISS = 1 if it was not found in the trace
*
NEXTOPW
          SET       OPWMISS,0
          LOAD      OPWI
          ADD       OPWI
          ADD       PCA
          ADD       2
          AND       A18
          STORE     OPWA
          INCREMENT OPWI
          IF        OPWI > OPWN THEN GOTO NXO_MISS
          IF        OPWI = 2 THEN GOTO NXO_2
          LOAD      OPW1
          RETURN
NXO_2
          LOAD      OPW2
          RETURN
NXO_MISS
          SET       OPWMISS,1
          RETURN

*
*  Register names
*
REG86
          LOAD      OPC
          ROTATE    RIGHT,6
REG20
          AND       7
          STORE     EAREG
REGNAME
          LOAD      EAREG
          CASE_OF   2,0
          OUTPUT    "R0"
          OUTPUT    "R1"
          OUTPUT    "R2"
          OUTPUT    "R3"
          OUTPUT    "R4"
          OUTPUT    "R5"
          OUTPUT    "SP"
          OUTPUT    "PC"
          CASE_END
          RETURN

************************************************************************
*
*  SHOWCYC - display a state that is not an instruction fetch
*
*            data  cycle  [operand | vector]
*
************************************************************************
SHOWCYC
          SET       RETURN_FLAGS,0
          POSITION  ABS,3
          LOAD      CURSTAT
          IF        2,2 = 1 THEN GOTO SHOW_W
          IF        1,0 <> 3 THEN GOTO SHOW_W
          LOAD      PCA                     ; DATOB: show only the byte
          IF        0,0 = 1 THEN GOTO SHOW_HB
          LOAD      OPC
          GOTO      SHOW_B
SHOW_HB
          LOAD      OPC
          ROTATE    RIGHT,8
SHOW_B
          POSITION  REL,3
          OUTPUT    ACCUMULATOR,O3
          GOTO      SHOW_CT
SHOW_W
          LOAD      OPC
          OUTPUT    ACCUMULATOR,O6
SHOW_CT
          POSITION  REL,2
          LOAD      CURSTAT
          IF        2,2 = 1 THEN GOTO SHOW_INT
          CASE_OF   1,0
          OUTPUT    "DATI "
          OUTPUT    "DATIP"
          OUTPUT    "DATO "
          OUTPUT    "DATOB"
          CASE_END
          GOTO      SHOW_TG
SHOW_INT
          OUTPUT    "INTR "
SHOW_TG
          POSITION  REL,2
          IF        TAGCUR = TG_OPER THEN OUTPUT "operand"
          IF        TAGCUR = TG_VEC THEN OUTPUT "vector"
          RETURN
