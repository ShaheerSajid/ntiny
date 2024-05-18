#ifndef __UART_TEST_H__
#define __UART_TEST_H__

#include "uart.h"
#include "stdlib.h"
#include "test.h"




/**
* Prototypes of Uart firmware tests \n
*/
int uart_test();

#ifdef Peak_poke
int uart_peak_poke_test ();
#endif

#ifdef loopback
#include "ee_printf.h"
#include "string.h"
int uart_loopback_test ();
#endif

#ifdef fucntional
#include "ee_printf.h"
#include "string.h"
int uart_fucntional_test ();
#endif


#endif
