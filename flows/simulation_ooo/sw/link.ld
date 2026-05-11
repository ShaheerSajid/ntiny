OUTPUT_FORMAT("elf32-littleriscv")
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 0x00004000
}

SECTIONS
{
    .text 0x00000000 :
    {
        *(.text.startup)
        *(.text)
        *(.text.*)
    } > RAM

    .rodata : ALIGN(4) { *(.rodata) *(.rodata.*) } > RAM
    .data   : ALIGN(4) { *(.data)   *(.data.*) }   > RAM
    .bss    : ALIGN(4) { *(.bss)    *(.bss.*)  }   > RAM

    /DISCARD/ : { *(.comment) *(.note.*) *(.eh_frame*) }
}
