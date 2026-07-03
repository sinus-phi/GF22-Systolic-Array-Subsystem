#include <stdint.h>

#define PERIPH_BASE     0x40000000UL
#define AHB1PERIPH_BASE (PERIPH_BASE + 0x00020000UL)
#define APB1PERIPH_BASE PERIPH_BASE
#define APB2PERIPH_BASE (PERIPH_BASE + 0x00010000UL)

#define RCC_BASE    (AHB1PERIPH_BASE + 0x3800UL)
#define GPIOA_BASE  (AHB1PERIPH_BASE + 0x0000UL)
#define USART2_BASE (APB1PERIPH_BASE + 0x4400UL)
#define USART1_BASE (APB2PERIPH_BASE + 0x1000UL)

#define REG32(addr) (*(volatile uint32_t *)(addr))

#define RCC_AHB1ENR  REG32(RCC_BASE + 0x30UL)
#define RCC_APB1ENR  REG32(RCC_BASE + 0x40UL)
#define RCC_APB2ENR  REG32(RCC_BASE + 0x44UL)

#define GPIOA_MODER  REG32(GPIOA_BASE + 0x00UL)
#define GPIOA_OTYPER REG32(GPIOA_BASE + 0x04UL)
#define GPIOA_OSPEEDR REG32(GPIOA_BASE + 0x08UL)
#define GPIOA_PUPDR  REG32(GPIOA_BASE + 0x0CUL)
#define GPIOA_ODR    REG32(GPIOA_BASE + 0x14UL)
#define GPIOA_BSRR   REG32(GPIOA_BASE + 0x18UL)
#define GPIOA_AFRL   REG32(GPIOA_BASE + 0x20UL)
#define GPIOA_AFRH   REG32(GPIOA_BASE + 0x24UL)

#define USART_SR(base)  REG32((base) + 0x00UL)
#define USART_DR(base)  REG32((base) + 0x04UL)
#define USART_BRR(base) REG32((base) + 0x08UL)
#define USART_CR1(base) REG32((base) + 0x0CUL)
#define USART_CR2(base) REG32((base) + 0x10UL)
#define USART_CR3(base) REG32((base) + 0x14UL)

#define RCC_CR       REG32(RCC_BASE + 0x00UL)
#define RCC_CFGR     REG32(RCC_BASE + 0x08UL)

#define RCC_CR_HSION  (1UL << 0)
#define RCC_CR_HSIRDY (1UL << 1)
#define RCC_CR_HSEON  (1UL << 16)
#define RCC_CR_PLLON  (1UL << 24)

#define RCC_CFGR_SW_MASK    (3UL << 0)
#define RCC_CFGR_SWS_MASK   (3UL << 2)
#define RCC_CFGR_HPRE_MASK  (0xFUL << 4)
#define RCC_CFGR_PPRE1_MASK (7UL << 10)
#define RCC_CFGR_PPRE2_MASK (7UL << 13)

#define USART_SR_RXNE (1UL << 5)
#define USART_SR_TXE  (1UL << 7)
#define USART_CR1_RE  (1UL << 2)
#define USART_CR1_TE  (1UL << 3)
#define USART_CR1_UE  (1UL << 13)

#define HSI_HZ 16000000UL
#define BAUD   9600UL

extern uint32_t _estack;
extern uint32_t _sidata;
extern uint32_t _sdata;
extern uint32_t _edata;
extern uint32_t _sbss;
extern uint32_t _ebss;

void Reset_Handler(void);

static void Default_Handler(void)
{
  while (1) {
  }
}

__attribute__((section(".isr_vector"), used))
void (*const vector_table[])(void) = {
  (void (*)(void))(&_estack),
  Reset_Handler,
  Default_Handler,
  Default_Handler,
  Default_Handler,
  Default_Handler,
  Default_Handler,
  0,
  0,
  0,
  0,
  Default_Handler,
  Default_Handler,
  0,
  Default_Handler,
  Default_Handler,
};

static void gpio_set_af(uint32_t pin, uint32_t af)
{
  if (pin < 8U) {
    GPIOA_AFRL = (GPIOA_AFRL & ~(0xFUL << (pin * 4U))) | (af << (pin * 4U));
  } else {
    uint32_t shift = (pin - 8U) * 4U;
    GPIOA_AFRH = (GPIOA_AFRH & ~(0xFUL << shift)) | (af << shift);
  }
}

static void gpio_set_mode(uint32_t pin, uint32_t mode)
{
  GPIOA_MODER = (GPIOA_MODER & ~(0x3UL << (pin * 2U))) | (mode << (pin * 2U));
}

static void gpio_set_pupd(uint32_t pin, uint32_t pupd)
{
  GPIOA_PUPDR = (GPIOA_PUPDR & ~(0x3UL << (pin * 2U))) | (pupd << (pin * 2U));
}

static void uart_init(uint32_t base)
{
  USART_CR1(base) = 0;
  USART_CR2(base) = 0;
  USART_CR3(base) = 0;
  USART_BRR(base) = (HSI_HZ + (BAUD / 2U)) / BAUD;
  USART_CR1(base) = USART_CR1_RE | USART_CR1_TE | USART_CR1_UE;
}

static int uart_rx_ready(uint32_t base)
{
  return (USART_SR(base) & USART_SR_RXNE) != 0;
}

static uint8_t uart_read(uint32_t base)
{
  return (uint8_t)(USART_DR(base) & 0xFFU);
}

static void uart_write(uint32_t base, uint8_t value)
{
  while ((USART_SR(base) & USART_SR_TXE) == 0) {
  }
  USART_DR(base) = value;
}

static void uart_write_str(uint32_t base, const char *str)
{
  while (*str != '\0') {
    uart_write(base, (uint8_t)*str++);
  }
}

static void clock_init_hsi_16mhz(void)
{
  RCC_CR |= RCC_CR_HSION;
  while ((RCC_CR & RCC_CR_HSIRDY) == 0) {
  }

  RCC_CFGR &= ~(RCC_CFGR_SW_MASK |
                RCC_CFGR_HPRE_MASK |
                RCC_CFGR_PPRE1_MASK |
                RCC_CFGR_PPRE2_MASK);
  while ((RCC_CFGR & RCC_CFGR_SWS_MASK) != 0) {
  }

  RCC_CR &= ~(RCC_CR_PLLON | RCC_CR_HSEON);
}

static void init_board(void)
{
  clock_init_hsi_16mhz();

  RCC_AHB1ENR |= (1UL << 0);   // GPIOA
  RCC_APB1ENR |= (1UL << 17);  // USART2
  RCC_APB2ENR |= (1UL << 4);   // USART1
  (void)RCC_AHB1ENR;

  // PA2/PA3: USART2 TX/RX to ST-LINK Virtual COM Port.
  gpio_set_mode(2, 2);
  gpio_set_mode(3, 2);
  gpio_set_af(2, 7);
  gpio_set_af(3, 7);
  gpio_set_pupd(2, 1);
  gpio_set_pupd(3, 1);

  // PA9/PA10: USART1 TX/RX to PYNQ-Z2 Arduino D8/D2.
  gpio_set_mode(9, 2);
  gpio_set_mode(10, 2);
  gpio_set_af(9, 7);
  gpio_set_af(10, 7);
  gpio_set_pupd(9, 1);
  gpio_set_pupd(10, 1);

  // PA5: LD2 green LED, heartbeat.
  gpio_set_mode(5, 1);
  GPIOA_OTYPER &= ~(1UL << 5);
  GPIOA_OSPEEDR |= (2UL << (5 * 2U));

  uart_init(USART1_BASE);
  uart_init(USART2_BASE);
}

static void copy_data_and_clear_bss(void)
{
  uint32_t *src = &_sidata;
  uint32_t *dst = &_sdata;
  while (dst < &_edata) {
    *dst++ = *src++;
  }

  for (dst = &_sbss; dst < &_ebss; dst++) {
    *dst = 0;
  }
}

void Reset_Handler(void)
{
  copy_data_and_clear_bss();
  init_board();

  uart_write_str(USART2_BASE, "\r\nNUCLEO-F411RE UART bridge ready @9600 8N1\r\n");
  uart_write_str(USART2_BASE, "USART1 PA10(D2)=PYNQ_TX, PA9(D8)=PYNQ_RX\r\n");

  uint32_t heartbeat = 0;
  uint32_t pynq_uart_seen = 0;
  while (1) {
    if (uart_rx_ready(USART1_BASE)) {
      pynq_uart_seen = 1;
      uart_write(USART2_BASE, uart_read(USART1_BASE));
    }

    if (uart_rx_ready(USART2_BASE)) {
      uart_write(USART1_BASE, uart_read(USART2_BASE));
    }

    heartbeat++;
    if (heartbeat == 250000UL) {
      GPIOA_BSRR = (GPIOA_ODR & (1UL << 5)) ? (1UL << (5 + 16U)) : (1UL << 5);
      if (!pynq_uart_seen) {
        uart_write(USART2_BASE, '.');
      }
      heartbeat = 0;
    }
  }
}
