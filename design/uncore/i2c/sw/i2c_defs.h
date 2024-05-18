#ifndef __I2C__DEFS_H__
#define __I2C__DEFS_H__


#define BASE_ADDR						0x2000000


#define REG_CLK_PRESCALER 				0x00 // word addressable
	// 	[15:0] Clock prescaler value
	// 	reset of bits are unused
#define REG_CTRL	          		 	0x01
	// 	[ 7:6] {i2C_en, interrupt_en}
	// 	reset of bits are unused
	
#define REG_RX							0x02
	// 	[7:0]  Output data recieved from I2C module

#define REG_STATUS						0x03
	//	[7:0] = { rx_ack, I2C_bussy, arbitration_lost, ..,..,.., transfer in progress (tip), intr_pending_flag }

#define REG_TX							0x04
	//	[7:0]  Input data to be transmited by I2C module

#define REG_CMD							0x05
	//  [7:0] = { start, stop, read, write, ack, reserved, IRQ_ACK}


#endif