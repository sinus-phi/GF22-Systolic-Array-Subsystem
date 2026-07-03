/*
 * Name: uart
 * Contributor(s):
 *    - Matti Käyrä	(matti.kayra@tuni.fi)
 *    - Mohamed Soliman (mohamed.w.soliman.tuni.fi)
 * Description:
 *    - helper functions to use uart
 * Notes:
 *    - addresses are to be moved to common mem map header
 */
#ifndef __UART_H__
#define __UART_H__

#include <stdint.h>

#define PERIPH_BASE 0x01300000
#define UART_OFFSET 0x100

#define RBR_THR_DLL *( volatile uint32_t* )(PERIPH_BASE + UART_OFFSET + 0x00)
#define IER_DLM     *( volatile uint32_t* )(PERIPH_BASE + UART_OFFSET + 0x04)
#define IIR_FCR     *( volatile uint32_t* )(PERIPH_BASE + UART_OFFSET + 0x08)
#define LCR         *( volatile uint32_t* )(PERIPH_BASE + UART_OFFSET + 0x0C)
#define MCR         *( volatile uint32_t* )(PERIPH_BASE + UART_OFFSET + 0x10)
#define LSR         *( volatile uint32_t* )(PERIPH_BASE + UART_OFFSET + 0x14)
#define MSR         *( volatile uint32_t* )(PERIPH_BASE + UART_OFFSET + 0x18)
#define SCR         *( volatile uint32_t* )(PERIPH_BASE + UART_OFFSET + 0x1C)

void uart_init(){
  // configure rx io cell
  volatile uint32_t temp =   *( volatile uint32_t* )(0x01400028);
  *( volatile uint32_t* )(0x01400028) = (temp | 3u);

  const uint32_t sys_clk_hz = 25000000u;
  const uint32_t baud = 9600u;
  const uint32_t divisor = (sys_clk_hz + (baud * 8u)) / (baud * 16u);

  // init uart settings (for typical tx/rx setup)
  IIR_FCR = 0x00u;
  LCR = 0x80u;
  RBR_THR_DLL = divisor & 0xffu;
  IER_DLM = (divisor >> 8) & 0xffu;
  LCR = 0x03u;
  IIR_FCR = 0xc7u;
  MCR = 0x20u;

}

int is_transmit_empty()
{
  return LSR & 0x20u;
}

void write_serial(char a)
{
  while (!is_transmit_empty()) {
  }
  RBR_THR_DLL = (uint32_t)a;
}

void uart_print(const char str[]){
  for (int i = 0; str[i] != '\0'; i++) {
    write_serial(str[i]);
  }
}

int uart_loopback_test(){

  RBR_THR_DLL = 'f';
  volatile char tmp_val='O';
  volatile uint32_t wait_loop=0;
  while(wait_loop<500){
    asm("nop");
    wait_loop++;
  }

  tmp_val = RBR_THR_DLL;
  if (tmp_val == 'f'){
    return 0; // pass
  }else{
    return 1; // failure
  }
}

#endif //__UART_H__
