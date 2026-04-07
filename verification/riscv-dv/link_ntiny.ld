/* Linker script for riscv-dv tests on ntiny SoC
 * RAM: 0x80000000
 * TOHOST: 0x0F000000 (special address monitored by testbench)
 */

OUTPUT_ARCH( "riscv" )
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;
  .text : { *(.text) }
  . = ALIGN(0x1000);
  .page_table : { *(.page_table) }
  .data : { *(.data) }
  .user_stack : { *(.user_stack) }
  .kernel_data : { *(.kernel_data) }
  .kernel_stack : { *(.kernel_stack) }
  .bss : { *(.bss) }
  _end = .;

  /* Map tohost to ntiny's monitored address */
  .tohost 0x0F000000 : { *(.tohost) }
}
