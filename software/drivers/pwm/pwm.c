#include "pwm.h"
#include <stdint.h>

//-----------------------------------------------------------------
// Locals
//-----------------------------------------------------------------
static volatile uint32_t *m_pwm;

//-----------------------------------------------------------------
// init: setting memory mapped based address of pwm.
//-----------------------------------------------------------------
void pwm_init (void)
{
	m_pwm = ( uint32_t *)pwm_base_addr;
	m_pwm[CONTROL_REG] =  0x0;
}


//-----------------------------------------------------------------
// set_compare1: setting value of pwm comapre1 register
//-----------------------------------------------------------------
void set_compare1 (uint32_t comapre_value)
{
	m_pwm[COMPARE1_REG] =  comapre_value;
}

//-----------------------------------------------------------------
// set_compare2: setting value of pwm comapre2 register
//-----------------------------------------------------------------
void set_compare2 (uint32_t comapre_value1)
{
	m_pwm[COMPARE2_REG] =  comapre_value1;
}

//-----------------------------------------------------------------
// set_prescaler: setting value of pwm prescaler register
//-----------------------------------------------------------------
void set_prescaler (uint32_t prescaler_value)
{
	m_pwm[PRESCALER_REG] =  prescaler_value;
}

//-----------------------------------------------------------------
// set_period1: setting value of pwm period1 register
//-----------------------------------------------------------------
void set_period1 (uint32_t period_reg_value)
{
	m_pwm[PERIOD1_REG] =  period_reg_value;
}

//-----------------------------------------------------------------
// set_period2: setting value of pwm period2 register
//-----------------------------------------------------------------
void set_period2 (uint32_t period_reg_value)
{
	m_pwm[PERIOD2_REG] =  period_reg_value;
}

//-----------------------------------------------------------------
// set_deadtime1: setting value of deadtime for complimentry PWM1
//-----------------------------------------------------------------
void set_deadtime1 (uint32_t deadtime1)
{
	m_pwm[DEADTIME1_REG] =  deadtime1;
}

//-----------------------------------------------------------------
// set_deadtime2: setting value of deadtime for complimentry PWM2
//-----------------------------------------------------------------
void set_deadtime2 (uint32_t deadtime2)
{
	m_pwm[DEADTIME2_REG] =  deadtime2;
}


//-----------------------------------------------------------------
// start: setting value of pwm control register
//-----------------------------------------------------------------
void pwm1_start ()
{
	m_pwm[CONTROL_REG] |=  0x1;
}

//-----------------------------------------------------------------
// start: setting value of pwm control register
//-----------------------------------------------------------------
void pwm2_start ()
{
	m_pwm[CONTROL_REG] |=  0x2;
}

//-----------------------------------------------------------------
//  stop: setting value of pwm control register
//-----------------------------------------------------------------
void pwm1_stop ()
{
	m_pwm[CONTROL_REG] &=  0xfe;
}

//-----------------------------------------------------------------
//  stop: setting value of pwm control register
//-----------------------------------------------------------------
void pwm2_stop ()
{
	m_pwm[CONTROL_REG] &=  0xfd;
}

//-----------------------------------------------------------------
//  read_control: reading value of pwm control register
//-----------------------------------------------------------------
uint32_t read_control ()
{
	return m_pwm[CONTROL_REG];
}

//-----------------------------------------------------------------
// pwm1_set_mode: setting value of pwm control register
//-----------------------------------------------------------------
void pwm1_set_mode (int com_re, int cen_edge)
{

	m_pwm[CONTROL_REG] = com_re? m_pwm[CONTROL_REG] | (0x1<<2): m_pwm[CONTROL_REG] & ~(0x1<<2);
	m_pwm[CONTROL_REG] = cen_edge? m_pwm[CONTROL_REG] | (0x1<<4): m_pwm[CONTROL_REG] & ~(0x1<<4);
	

}
//-----------------------------------------------------------------
// pwm2_set_mode: setting value of pwm control register
//-----------------------------------------------------------------
void pwm2_set_mode (int com_re, int cen_edge)
{

	m_pwm[CONTROL_REG] = com_re? m_pwm[CONTROL_REG] | (0x1<<3): m_pwm[CONTROL_REG] & ~(0x1<<3);
	m_pwm[CONTROL_REG] = cen_edge? m_pwm[CONTROL_REG] | (0x1<<5): m_pwm[CONTROL_REG] & ~(0x1<<5);
	

}
