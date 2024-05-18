#ifndef TIMER_TEST_H_
#define TIMER_TEST_H_
#include <stdint.h>
#include"timer.h"
#include "test.h"


int timer_test(void);

#ifdef Peak_poke
int timer_peak_poke_test ();
#endif

#ifdef fucntional
#include "ee_printf.h"
#include "string.h"
int timer_fucntional_test ();
#endif


#endif