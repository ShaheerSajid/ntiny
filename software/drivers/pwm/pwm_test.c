 #include"pwm_test.h"
#include "timer.h"
#include <stdint.h>

static volatile uint32_t *m_pwm = (volatile uint32_t *)pwm_base_addr;
int pwm_test (void)
{	
	pwm_init();
	set_compare1 (191);
	set_compare2 (128);
	pwm1_start();
	pwm2_start();
	// delay 1 sec
	delay_ms (10000);
	pwm1_stop();
	pwm2_stop();

	uint32_t register_list[] = {PERIOD1_REG,PERIOD1_REG,COMPARE1_REG,COMPARE2_REG,DEADTIME1_REG,DEADTIME2_REG,CONTROL_REG};

	for ( int registers = 0; registers <8; registers++) // iterating through all 5 registers of PWM
	{
		for (int i = 0; i<8; i++) // setting every single bits of the register and conforming it
		{
			poke_reg(m_pwm,register_list[registers],1<<i);
			
			if (peak_reg(m_pwm,register_list[registers])!= (1<<i))
				{
					ee_printf ("PWM register at address map %d is not working correctly\n",register_list[registers]);
					return 1;
				}
		}
	}

	return 0;
}
