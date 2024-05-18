#ifndef __PWM_H__
#define __PWM_H__

#include <stdint.h>
#include"ee_printf.h"

//-----------------------------------------------------------------
// Memory Mapped Addressing:
//-----------------------------------------------------------------

#define pwm_base_addr 0x2001000
#define PRESCALER_REG  0x00

//	control register for controlling PWM modules
//	{8'b0, inverting2,inverting1,center_edge2,center_edge1,com_re2,com_re1,pwm_2_en,pwm_1_en}	
//	com_re -> complementry_redundent
#define CONTROL_REG    0x01 


#define PERIOD1_REG    0x02
#define PERIOD2_REG    0x03 
#define COMPARE1_REG   0x04
#define COMPARE2_REG   0x05 
#define DEADTIME1_REG  0x06 
#define DEADTIME2_REG  0x07 
//-----------------------------------------------------------------
// Prototypes:
//-----------------------------------------------------------------

void pwm_init (void); 

void set_compare1 (uint32_t comapre_value);

void set_compare2 (uint32_t comapre_value1);

void set_prescaler (uint32_t prescaler_value);

void set_period1 (uint32_t period_reg_value);

void set_period2 (uint32_t period_reg_value);

void set_deadtime1 (uint32_t deadtime1);

void set_deadtime2 (uint32_t deadtime2);

void pwm1_start (void);

void pwm2_start (void);

void pwm1_stop (void);

void pwm2_stop (void);

uint32_t read_control ();

void pwm1_set_mode (int com_re, int cen_edge);
void pwm2_set_mode (int com_re, int cen_edge);

#endif
