OUTPUT_FORMAT("elf32-littleriscv", "elf32-littleriscv", "elf32-littleriscv")
/* No GROUP() — this is a bare-metal payload. The Linux toolchain's
 * default -lc would pull in dynamic libc.so.6 stubs (PLT/GOT relocs
 * with no loader to resolve them) and crashes when called. */
OUTPUT_ARCH( "riscv" )
ENTRY( _init )

MEMORY
{
    /* Total RAM: 128 MiB starting at 0x80000000.
       OpenSBI occupies the first 4 MiB (0x80000000 - 0x803FFFFF).
       FreeRTOS payload starts precisely at 0x80400000. */
    RAM (rwx) : ORIGIN = 0x80400000, LENGTH = 124M
}

SECTIONS
{
    .init           : { *(.init) } > RAM
    .RESET_HANDLER  : { *(.RESET_HANDLER) } > RAM
    .init_vector_table : { *(.init_vector_table) } > RAM
    
    /* Code Section */
    .text : {
        . = ALIGN(4);
        *(.text.init)    /* Keeps bootstrap entry code at the absolute front */
        *(.text .text.*)
        _etext = .;
    } > RAM

    /* Read-Only Data Section */
    .rodata : {
        . = ALIGN(4);
        *(.rodata .rodata.*)
        _erodata = .;
    } > RAM

    /* Initialized Data Section */
    .data : {
        . = ALIGN(4);
        _data_start = .;
        *(.data .data.*)
        
        /* RISC-V Global Pointer optimization symbol allocation */
        . = ALIGN(16);
        __global_pointer$ = . + 0x800;
        *(.sdata .sdata.*)
        _edata = .;
    } > RAM

    /* Uninitialized Data Section (BSS) */
    .bss : {
        . = ALIGN(4);
        _bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > RAM

    /* Early Boot Stack Allocation 
       Used exclusively before the FreeRTOS scheduler starts up 
       and allocates individual task stacks out of the heap. */
    .stack : {
        . = ALIGN(16);
        _stack_bottom = .;
        . += 0x4000; /* Allocates 16 KiB for the boot frame stack */
        _stack_top = .;
    } > RAM

    _end = .;
}