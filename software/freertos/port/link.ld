/*
 * link.ld — ntiny FreeRTOS, S-mode payload at 0x80400000.
 *
 * Layout matches OpenSBI's FW_PAYLOAD_OFFSET=0x400000 (see
 * software/linux/opensbi-platform/objects.mk). OpenSBI itself
 * occupies 0x80000000..0x803fffff; FreeRTOS image sits at
 * 0x80400000 and grows up. Stack lives in .bss as _stack[].
 */

OUTPUT_ARCH( "riscv" )
OUTPUT_FORMAT( "elf32-littleriscv" )
ENTRY( _start )

MEMORY
{
    RAM  (rwx) : ORIGIN = 0x80400000, LENGTH = 0x01C00000  /* 28 MB */
}

_stack_size = 0x4000;   /* 16 KB main stack — used until vTaskStartScheduler */

SECTIONS
{
    .text 0x80400000 : ALIGN(4)
    {
        KEEP(*(.text.entry))
        *(.text.freertos_trap)
        *(.text.start_first_task)
        *(.text .text.*)
    } > RAM

    .rodata : ALIGN(4)
    {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } > RAM

    .data : ALIGN(4)
    {
        _data_start = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        _data_end = .;
    } > RAM

    .bss : ALIGN(16)
    {
        _bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
        _bss_end = .;

        . = ALIGN(16);
        _stack_bottom = .;
        . = . + _stack_size;
        . = ALIGN(16);
        _stack_top = .;
    } > RAM

    _heap_start = .;
    _heap_end   = ORIGIN(RAM) + LENGTH(RAM);

    /DISCARD/ : { *(.comment) *(.note .note.*) *(.eh_frame) }
}
