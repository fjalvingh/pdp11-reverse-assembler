# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

This repository holds a PDP-11 inverse assembler for HP logic analyzers. The main target is the 16702A, though it also works on the 1650/16500/16600/16700 series. It decodes Unibus bus cycles into PDP-11 mnemonics, displayed in octal.

The product is a single HP IAL (Inverse Assembler Language) source file, `src/IPDP11.S`. Everything else is either build tooling or a Python test harness that runs that IAL source directly.

The IA has not yet been run on a real analyzer. Hardware behaviour is assumed from the HP 10391B manual. These points in particular still need confirming on hardware:

- `INPUT REL,0`
- overwriting output after `POSITION ABS,1`
- whether tags persist on re-sync

## Commands

```sh
./build.sh                       # assemble src/IPDP11.S -> out/IPDP11.R, out/IPDP11.LST, out/IPDP11
python3 test/test_opcodes.py     # all 65536 opcodes vs. reference disassembler (arg N = step, for a quick run)
python3 test/test_trace.py [-v]  # emulated program trace: DMA, interrupts, traps, I/O-page code
python3 test/test_stress.py 20   # randomized long runs; fails if any scenario > 0.5% wrong lines
```

### Build details

- `build.sh` runs the DOS assembler `iadisk/ASM.EXE` under [emu2](https://github.com/dmsc/emu2). It looks for emu2 in `$EMU2`, then on `PATH`, then builds it from source into `tools/emu2/` (gitignored).
- `build.sh` stages a temp directory containing:
  - `HP64700/TABLES/AIAL`, copied from `iadisk/TABLES/AIAL.txt`. The assembler requires the table at that path.
  - A CRLF copy of the source.
- Success is `Errors= 0` in the listing.
- `tools/mkiafile.py` then wraps the `.R` file into the analyzer's LIF disk file (Invasm option B). Its docstring documents the format. Only option byte B has been verified.
- Rebuilding only changes timestamps in `out/` when the source is unchanged. Don't commit those.
- `iadisk/` is the vendor HP 10391B package. Treat it as read-only. `iadisk/EXAMPLES/` has HP's 68010 and 8085 IAs, which are useful as IAL idiom references.

## Architecture

### `src/IPDP11.S` (IAL)

The analyzer calls the IA once per listing state, with ADDR/DATA/STAT available. Each state carries a user tag that says what it is: FETCH, OPER, DATA or VEC. The flow is:

1. `START` reads the tag.
   - Untagged and not synced: the state shows as a raw cycle.
   - Invasm sync (the system tag bits): the state is treated as a FETCH.
2. `DECODE` disassembles the fetch. `EA` handles operand modes. `PCREL` computes PC-relative targets, with sign extension and 16-bit wrap in the I/O page.
3. Decoding also sets `TTYPE`, the prediction of where the next fetch comes from: `TT_SEQ`, `TT_BRANCH`, `TT_OPWABS`, `TT_OPWREL`, `TT_READ` or `TT_UNKN`.
4. `SCAN` looks ahead up to `SCANMAX` states with `INPUT REL` and tags them:
   - extension words (OPER);
   - the vector pair V, V+2 below `VEC_LIMIT`, detected by the stack-push signature or an INTR cycle (VEC);
   - other cycles (DATA);
   - the predicted next fetch (FETCH), so that the chain continues when the listing reaches it.
5. For an unknown target, `SC_NEAR`/`CTLXFER` pick the first read X that is followed by a read of X+2, or a control-transfer opcode at X.
6. Recovery: when the chain is lost, unclaimed reads are tried as guesses, up to `GUESSMAX`. A guess is kept only if its own next fetch is found (the `CONF` flag). Otherwise the line is overwritten and shown as a data cycle.
7. The tunables `SCANMAX`, `GUESSMAX` and `VEC_LIMIT` are at the top of the file.

### IAL constraints to respect when editing

- There is a single 32-bit accumulator.
- `SET` immediates must be in -8..+7. Load larger constants another way.
- Labels have 15 significant characters.
- Octal constants use the `Q` suffix.
- A `CALL` inside `CASE_OF` returns after `CASE_END`.
- `TAG_WITH` tags the last `INPUT` state.
- Bits 16–17 of `INPUT_TAG` are system sync bits.
- `RETURN_FLAGS` bit 0 = line decoded.
- At most 4 output lines, and at most 16 nested CALLs.
- The analyzer aborts a state after `MAX_INSTRUCTION` (30000) IAL instructions. `test_stress.py` reports the worst case.

### Test harness (`test/`)

- `ialsim.py` is an IAL interpreter plus an analyzer listing model (`Analyzer`: sync, tags, `INPUT REL`). It enforces the constraints above (SET range, line count, CALL depth, instruction limit). If you use an IAL construct it doesn't model, extend the simulator rather than working around it.
- `pdp11dis.py` is the reference disassembler. Its output format must match the IA's text exactly; `test_opcodes` compares strings.
- `unibus_sim.py` is a PDP-11 CPU/Unibus cycle model. It covers trap and interrupt cycle orders, DMA injection and the MMU `phys()`. It also includes a mini assembler (`Asm`, with operand helpers such as `IMM`, `REL` and `IDX`). `test_trace.program()` uses it to build the test program.
- `test_trace.check()` compares each listing line with the ground truth recorded by the CPU model.
- After any change to `src/IPDP11.S`, run all three tests and `./build.sh`. The real assembler can reject things the simulator accepts.
