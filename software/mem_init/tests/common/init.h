void int_disable(void);
void int_enable(void);


__attribute__((section (".ISR_SOFT_ASM"),)) __attribute__((interrupt())) __attribute__((weak))void ISR_SOFT_ASM();
__attribute__((section (".ISR_EXT_ASM"))) __attribute__((interrupt())) __attribute__((weak))void ISR_EXT_ASM();
__attribute__((section (".ISR_TIMER_ASM"))) __attribute__((interrupt())) __attribute__((weak))void ISR_TIMER_ASM();
__attribute__((section (".ISR_DEFAULT_ASM"))) __attribute__((interrupt())) __attribute__((weak))void ISR_DEFAULT_ASM();


