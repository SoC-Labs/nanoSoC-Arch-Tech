/*
 *-----------------------------------------------------------------------------
 * The confidential and proprietary information contained in this file may
 * only be used by a person authorised under and to the extent permitted
 * by a subsisting licensing agreement from Arm Limited or its affiliates.
 *
 *            (C) COPYRIGHT 2010-2013 Arm Limited or its affiliates.
 *                ALL RIGHTS RESERVED
 *
 * This entire notice must be reproduced on all copies of this file
 * and copies of this file may only be made by a person if such person is
 * permitted to do so under the terms of a subsisting license agreement
 * from Arm Limited or its affiliates.
 *
 *      SVN Information
 *
 *      Checked In          : $Date: 2017-10-10 15:55:38 +0100 (Tue, 10 Oct 2017) $
 *
 *      Revision            : $Revision: 371321 $
 *
 *      Release Information : Cortex-M System Design Kit-r1p1-00rel0
 *-----------------------------------------------------------------------------
 */

 /*

 UART functions for retargetting

 */
#ifdef CORTEX_M0
#include "CMSDK_CM0.h"
#endif

#ifdef CORTEX_M0PLUS
#include "CMSDK_CM0plus.h"
#endif

#ifdef CORTEX_M3
#include "CMSDK_CM3.h"
#endif

#ifdef CORTEX_M4
#include "CMSDK_CM4.h"
#endif


#include "nanosoc_memmap.h"

#define CLKFREQ    NANOSOC_SYS_CLK_FREQ_HZ
#define BAUDRATE   38400
#define BAUDCLKDIV (CLKFREQ / BAUDRATE)

void UartStdOutInit(void)
{
  CMSDK_UART2->CTRL    = 0x00;       // disable whie reprogramming
  CMSDK_UART2->BAUDDIV = BAUDCLKDIV; // (240MHz/BAUDRATE) in 16.4 format
  CMSDK_UART2->CTRL    = 0x01;       // TX, standard UART2
  CMSDK_USRT2->BAUDDIV = 0xf0;       // (prescaler value = ~((div+1)[7:0))
  CMSDK_USRT2->CTRL    = 0x03;       // RX+TX, FT1248 USRT
  CMSDK_GPIO1->ALTFUNCSET = (1<<5);  // UART2 mapped to GP1[5,4]
  return;
}

void Uart2StdOutInit(void)
{
// ensure full character shift before reprogramming UART2
  CMSDK_DUALTIMER->Timer1Load = (11 * BAUDCLKDIV); // 10+1 x baud tick clock
  CMSDK_DUALTIMER->Timer1BGLoad = (10 * BAUDCLKDIV); // 10 x baud tick clock
  CMSDK_DUALTIMER->Timer1IntClr = 1;
  CMSDK_DUALTIMER->Timer1Control = 0xC3; // enable, periodic, 32-bit
  while ((CMSDK_DUALTIMER->Timer1RIS & 1)== 0) ; // wait until any UART character time
// reinitialize UART2
///  CMSDK_UART2->CTRL    = 0x00;       // disable whie reprogramming
///  CMSDK_UART2->BAUDDIV = BAUDCLKDIV; // (240MHz/BAUDRATE) in 16.4 format
///  CMSDK_UART2->CTRL    = 0x01;       // RX+TX, standard UART2
  CMSDK_GPIO1->ALTFUNCSET = (1<<5);  // UART2 mapped to GP1[5,4]
  CMSDK_USRT2->CTRL    = 0x00;       // RX+TX, FT1248 USRT disabled
  CMSDK_USRT2->BAUDDIV = 0xf0;       // (prescaler value = ~((div+1)[7:0))
  CMSDK_USRT2->CTRL    = 0x03;       // RX+TX, FT1248 USRT disabled
  return;
}

// Output a character
//
// FPGA bring-up fix (nanosoc_m0_soc pynq flow, pynq_z2_04, 2026-07-06):
// always emit on UART2 and treat the SoCDebug USRT2 (FT1248/ADP drain) as
// best-effort with a BOUNDED wait. As shipped, UartStdOutInit() enables
// USRT2 (CTRL=0x03) and this function then routed ALL console output
// exclusively to USRT2 with an unbounded THR spin; on FPGA builds whose
// FT1248 drain-loop does not actually drain, the very first character hung
// the application silently (UART2 showed nothing after the stage-0 boot
// markers). UART2 always drains at its programmed baud so its wait stays
// unbounded; the USRT2 side can no longer wedge the app and still receives
// every character whenever the ADP/FT1248 host is really draining.
unsigned char UartPutc(unsigned char my_ch)
{
  static unsigned char usrt2_stuck = 0; // latched on first drain timeout
  unsigned int budget = 200000u;      // ~40 ms @ 25 MHz; >> one USRT frame
  while (CMSDK_UART2->STATE & 1); // Wait if Transmit Holding register full
  CMSDK_UART2->DATA = my_ch; // write to transmit holding register
  if ((CMSDK_USRT2->CTRL & 1)==0) {
    CMSDK_USRT2->DATA = my_ch; // (also write to transmit holding register)
  } else if (usrt2_stuck == 0) {
    while ((CMSDK_USRT2->STATE & 1) && (--budget != 0u)); // bounded wait
    if (budget != 0u)
      CMSDK_USRT2->DATA = my_ch; // write to transmit holding register
    else
      usrt2_stuck = 1; // drain dead: stop waiting on it (pay 40 ms once)
  }
  return (my_ch);
}
// Get a character
unsigned char UartGetc(void)
{
  while (((CMSDK_UART2->STATE & 2)==0) & ((CMSDK_USRT2->STATE & 2)==0));
  if ((CMSDK_UART2->STATE & 2)==2) return (CMSDK_UART2->DATA);
  if ((CMSDK_USRT2->STATE & 2)==2) return (CMSDK_USRT2->DATA);
}

void UartEndSimulation(void)
{
  UartPutc((char) 0x4); // End of simulation
  while(1);
}

