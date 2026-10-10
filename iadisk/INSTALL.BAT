ECHO OFF
CLS
ECHO  ************************************************************************
ECHO  *            Inverse Assember Development Package Installation
ECHO  *
ECHO  * Copying the HP 10391B Inverse Assembler Development Package from
ECHO  * Drive A: to the current drive.  To stop this process, press CTRL-C.
ECHO  *
ECHO  ************************************************************************
COPY A:\PROGRAMS\*.*
COPY A:\EXAMPLES\*.*
ECHO  ************************************************************************
ECHO  *
ECHO  * Creating subdirectory \HP64700\TABLES and copying the assembler table
ECHO  * from Drive A: to that subdirectory.
ECHO  *
ECHO  ************************************************************************
CD \
MKDIR HP64700
CD \HP64700
MKDIR TABLES
CD TABLES
COPY A:\TABLES\*.*
CD \
ECHO Installation Complete!
