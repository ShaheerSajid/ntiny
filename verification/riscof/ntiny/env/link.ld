OUTPUT_ARCH( "riscv" )
ENTRY(rvtest_entry_point)

MEMORY
{
  IMEM (rwx) : ORIGIN = 0x00000000, LENGTH = 0x200000
  DMEM (rwx) : ORIGIN = 0x00300000, LENGTH = 0x4000
}

SECTIONS
{
  .text.init : { *(.text.init) } > IMEM
  . = ALIGN(0x100);
  .text : { *(.text) } > IMEM

  .data : { *(.data) *(.data.*) *(.data.string) } > DMEM
  .sdata : { *(.sdata) *(.sdata.*) } > DMEM
  .bss (NOLOAD) : { *(.bss) *(.bss.*) } > DMEM

  /* tohost at fixed bus address — no backing memory needed, testbench monitors bus writes */
  .tohost 0x0F000000 (NOLOAD) : { *(.tohost) }

  _end = .;
}
