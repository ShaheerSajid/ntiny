#include "init.h"
#include "csr.h"
#include "gpio.h"
int main(void);


void int_disable(void) {
  csr_clear(mstatus , (1<<3) );
}
void int_enable(void) {
  csr_set(mstatus , (1<<3) );
}

void ISR_DEFAULT_ASM()
{
}
void ISR_EXT_ASM()
{
}
void ISR_SOFT_ASM()
{
}
void ISR_TIMER_ASM()
{
}


__attribute__((section (".RESET_HANDLER"), naked))
void RESET_HANDLER()
{
	__asm("mv  x1, x0");
	__asm("mv  x2, x1");
	__asm("mv  x3, x1");
	__asm("mv  x4, x1");
	__asm("mv  x5, x1");
	__asm("mv  x6, x1");
	__asm("mv  x7, x1");
	__asm("mv  x8, x1");
	__asm("mv  x9, x1");
	__asm("mv x10, x1");
	__asm("mv x11, x1");
	__asm("mv x12, x1");
	__asm("mv x13, x1");
	__asm("mv x14, x1");
	__asm("mv x15, x1");
	__asm("mv x16, x1");
	__asm("mv x17, x1");
	__asm("mv x18, x1");
	__asm("mv x19, x1");
	__asm("mv x20, x1");
	__asm("mv x21, x1");
	__asm("mv x22, x1");
	__asm("mv x23, x1");
	__asm("mv x24, x1");
	__asm("mv x25, x1");
	__asm("mv x26, x1");
	__asm("mv x27, x1");
	__asm("mv x28, x1");
	__asm("mv x29, x1");
	__asm("mv x30, x1");
	__asm("mv x31, x1");

	__asm("csrrw x0, mtvec, x0");
	__asm(".option push\n"
	".option norelax\n"
	"la gp, __global_pointer$\n"
	".option pop");
	__asm("la sp, __stack_top");
	__asm("add s0, sp, zero");
	extern char __bss_start,__BSS_END__;
	char *dst;
	for (dst = &__bss_start; dst< &__BSS_END__; dst++)
	{
	*dst = 0;
	__asm("nop");
	}
	main();
	__asm("jal x0, RESET_HANDLER");
}

__attribute__((section (".init"), naked))
void _init(){
	__asm("jal x0, RESET_HANDLER");
  __asm("jal x0, ISR_DEFAULT_ASM");
  __asm("jal x0, ISR_DEFAULT_ASM");
  __asm("jal x0, ISR_SOFT_ASM");
  __asm("jal x0, ISR_DEFAULT_ASM");
  __asm("jal x0, ISR_DEFAULT_ASM");
  __asm("jal x0, ISR_DEFAULT_ASM");
	__asm("jal x0, ISR_TIMER_ASM");	
  __asm("jal x0, ISR_DEFAULT_ASM");
  __asm("jal x0, ISR_DEFAULT_ASM");
  __asm("jal x0, ISR_DEFAULT_ASM"); 
	__asm("jal x0, ISR_EXT_ASM");
}
