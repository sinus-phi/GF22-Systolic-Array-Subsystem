/*
 * Project: Edu4chip
 * Description: 
 *   - crt0 ("c runtime zero") file
 *   - program run specifics outside main function
 * Contributors:
 *   - Antti Nurmi (antti.nurmi@tuni.fi)
 *   - Matti Käyrä (matti.kayra@tuni.fi)
 * Notes:
 *   - Minimimal implementation, no irq support
 */

  .section .text

reset_handler:
  la x2, stack
  la t0, __bss_start
  la t1, __bss_end

clear_bss:
  bgeu t0, t1, clear_bss_done
  sw zero, 0(t0)
  addi t0, t0, 4
  j clear_bss

clear_bss_done:
  la ra, postMain 
  j main

/* Didactic specific return code pass over through jtag */
  .global postMain
postMain:
  li t0, 0x01200380
  li t1, 0x80000000
  or a0, a0, t1
  sw a0, 0(t0)
  j  loop

  .global changeStack
changeStack:
  mv sp, a2
  jr a1

  .section .vectors, "ax"
  .option norvc;
  .org 0x0
  jal x0, default_handler
  jal x0, default_handler
  jal x0, default_handler
  jal x0, default_handler
  jal x0, default_handler
  jal x0, default_handler
  jal x0, default_handler
  jal x0, default_handler
  jal x0, default_handler
  jal x0, default_handler
  jal x0, default_handler
  jal x0, default_handler
  jal x0, default_handler
  jal x0, default_handler
  jal x0, default_handler
  jal x0, default_handler
  jal x0, default_handler
  jal x0, default_handler
  jal x0, default_handler
  jal x0, default_handler
  jal x0, default_handler
  jal x0, default_handler
  jal x0, default_handler
  jal x0, default_handler
  jal x0, default_handler
  jal x0, default_handler
  jal x0, default_handler
  jal x0, default_handler
  jal x0, default_handler
  jal x0, default_handler
  jal x0, default_handler
  jal x0, default_handler

  //// reset vector
  .org 0x80
  jal x0, reset_handler

  .org 0x84
loop:
  j loop

default_handler:
  mret
