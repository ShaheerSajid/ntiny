# JTAG debug — Verilator + OpenOCD + GDB

End-to-end flow for bringing up the Debug Module (DM/DTM) against
a Verilator sim before any FPGA bring-up. Same hardware and same
OpenOCD config will work on the Zybo Z7-10 once the FPGA flow
lands — only the OpenOCD adapter line changes.

## Prereqs

- `openocd` ≥ 0.12 with riscv-dbg backend (`/usr/local/bin/openocd`)
- `riscv64-unknown-elf-gdb` (multiarch, handles RV32) at
  `/opt/riscv_bitmanip/bin/` or `/opt/riscv/bin/`

## 1. Build the sim with JTAG DPI

```
cd flows/simulation
make verilator_build_jtag
```

Adds `+define+JTAG_DPI` to compile flags and pulls in `SimJTAG.v`,
`SimJTAG.cc`, `remote_bitbang.cc`. The resulting `Vtb_soc_top`
opens a TCP listener on `localhost:5555` on the first JTAG tick
(~50 cycles after reset).

## 2. Launch the sim with a baremetal image

```
make mem_init        # produces ram.hex from software/build/baremetal.bin
./Vtb_soc_top --timeout 100000000 &
```

Sim runs free until OpenOCD halts the core. Increase `--timeout`
for longer interactive sessions.

## 3. Attach OpenOCD

```
openocd -f software/flash/jtag_rbb.cfg
```

`jtag_rbb.cfg` selects `adapter driver remote_bitbang` on
`localhost:5555` to pair with the SimJTAG DPI listener.

Expected log:
```
Info : Listening on port 6666 for tcl connections
Info : Listening on port 4444 for telnet connections
Info : remote_bitbang driver initialized
Info : This adapter doesn't support configurable speed
Info : JTAG tap: riscv.cpu tap/device found: 0x10e31913 (mfg: 0x489 (...), part: 0xe319, ver: 0x1)
Info : datacount=2 progbufsize=0
Info : Examined RISC-V core; found 1 harts
Info : starting gdb server for riscv.cpu.0 on 3333
```

If `IDCODE` reads `0xffffffff` or `0x00000000` — TAP FSM is stuck
or DPI socket isn't connected.

## 4. Smoke probes via OpenOCD telnet

```
telnet localhost 4444
> halt
> reg
> mdw 0x80000000 8     # peek at start of RAM
> resume
```

`halt` exercises `dmcontrol.haltreq`; `reg` exercises abstract
register access (`ar_*` interface in dm.sv); `mdw` exercises
abstract memory access (`am_*` interface).

## 5. GDB attach

```
riscv64-unknown-elf-gdb software/build/baremetal.elf
(gdb) target extended-remote :3333
(gdb) monitor halt
(gdb) info registers
(gdb) b main
(gdb) continue
```

Single-step and breakpoints exercise the full DM command pipeline.

## Bug class to watch for

The DM has not been driven by OpenOCD before in this codebase.
Likely first failure modes:

- **TAP FSM**: TCK/TDI/TMS are async to `clk_i`; `dtm.sv` shifts
  on `posedge tck_i`, registers cross to `clk_i` via
  `dmi_to_dm_sync`. If the synchroniser drops a pulse, OpenOCD
  retries — symptom is unusually slow scans.
- **abstractcs busy**: `dm.sv` clears `cmderr` only on explicit
  write of 1's. If a transient cmderr leaks, all subsequent
  abstract commands fail until cleared.
- **regaccess vs memaccess**: `cmdtype=0` (regaccess) vs `2`
  (memaccess) decode in `dm.sv` is OK by inspection; bug might
  be in `aasize` / `aapostincrement` for memaccess bursts.
- **No progbuf**: `progbufsize=0` (DM advertises). OpenOCD will
  fall back to abstract-only commands. If it tries progbuf, that's
  a config mismatch.
