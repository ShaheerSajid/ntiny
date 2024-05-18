/* Script for -z combreloc */
/* Copyright (C) 2014-2020 Free Software Foundation, Inc.
   Copying and distribution of this script, with or without modification,
   are permitted in any medium without royalty provided the copyright
   notice and this notice are preserved.  */
OUTPUT_FORMAT("elf32-littleriscv", "elf32-littleriscv",
	      "elf32-littleriscv")
GROUP(-lc -lgloss -lgcc -lm)
OUTPUT_ARCH(riscv)
MEMORY
{
  ROM (rwx)  : ORIGIN = 0x00000000, LENGTH = 0x8000
  RAM (rwx)  : ORIGIN = 0x00010000, LENGTH = 0x2000 
}
ENTRY(_init)
SEARCH_DIR("/opt/riscv64_new/riscv64-unknown-elf/lib");
SECTIONS
{
  /* Read-only sections, merged into text segment: */
  PROVIDE (__executable_start = SEGMENT_START("text-segment", 0x10000)); . = SEGMENT_START("text-segment", 0x10000) + SIZEOF_HEADERS;
  PROVIDE(__stack_top = ORIGIN(RAM) + LENGTH(RAM));

  .init           		: { *(.init) } > ROM
  .RESET_HANDLER  		: { *(.RESET_HANDLER) } > ROM
  .ISR_SOFT_ASM       : { *(.ISR_SOFT_ASM) } > ROM
  .ISR_TIMER_ASM  		: { *(.ISR_TIMER_ASM) } > ROM
  .ISR_EXT_ASM    		: { *(.ISR_EXT_ASM) } > ROM
  .ISR_DEFAULT_ASM    : { *(.ISR_DEFAULT_ASM) } > ROM
  .text           		:
  {
    *(.text.unlikely .text.*_unlikely .text.unlikely.*)
    *(.text.exit .text.exit.*)
    *(.text.startup .text.startup.*)
    *(.text.hot .text.hot.*)
    *(SORT(.text.sorted.*))
    *(.text .stub .text.* .gnu.linkonce.t.*)
    /* .gnu.warning sections are handled specially by elf.em.  */
    *(.gnu.warning)
  } > ROM 
  PROVIDE (__etext = .);
  PROVIDE (_etext = .);
  PROVIDE (etext = .);
  .rodata         : { *(.rodata .rodata.* .gnu.linkonce.r.*) } > RAM
  .data           :
  {
    __DATA_BEGIN__ = .;
    *(.data .data.* .gnu.linkonce.d.*)
    SORT(CONSTRUCTORS)
     __SDATA_BEGIN__ = .;
    *(.srodata.cst16) *(.srodata.cst8) *(.srodata.cst4) *(.srodata.cst2) *(.srodata .srodata.*)
   *(.sdata .sdata.* .gnu.linkonce.s.*)
  } > RAM
  
 
  _edata = .; PROVIDE (edata = .);
  . = .;
  __bss_start = .;
  
  .sbss           :
  {
    *(.dynsbss)
    *(.sbss .sbss.* .gnu.linkonce.sb.*)
    *(.scommon)
  } > RAM
  .bss            :
  {
   *(.dynbss)
   *(.bss .bss.* .gnu.linkonce.b.*)
   *(COMMON)
   /* Align here to ensure that the .bss section occupies space up to
      _end.  Align after .bss to ensure correct alignment even if the
      .bss section disappears because there are no input sections.
      FIXME: Why do we need it? When there is no .bss section, we do not
      pad the .data section.  */
   . = ALIGN(. != 0 ? 32 / 8 : 1);
  } > RAM
  
  . = ALIGN(32 / 8);
  . = SEGMENT_START("ldata-segment", .);
  . = ALIGN(32 / 8);
  __BSS_END__ = .;
    __global_pointer$ = MIN(__SDATA_BEGIN__ + 0x800,
		            MAX(__DATA_BEGIN__ + 0x800, __BSS_END__ - 0x800));
  _end = .; PROVIDE (end = .);
}
