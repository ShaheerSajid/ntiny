#ifndef GPIO_TEST_H_
#define GPIO_TEST_H_

#include "gpio.h"
#include "test.h"



int gpio_test();

#ifdef Peak_poke
int gpio_peak_poke_test ();
#endif

#ifdef fucntional
#include "ee_printf.h"
#include "string.h"
int gpio_fucntional_test ();
#endif


#endif