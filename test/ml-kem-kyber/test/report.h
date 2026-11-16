/*
 * Progress / result reporting for hornet_kyber.c on both HORNET cores.
 *
 * legacy (-DHORNET_LEGACY): every code is written to the debug interface (0x10008010); the
 *   testbench (soc/legacy/barebones_top_tb.v) prints the cycle of each write and stops on 'P'/'F'.
 * main (default): the cycle counter is recorded at every code and the list is printed over the
 *   UART at the end (so printing does not disturb the measurement), in the same
 *   "cycle <n> : <code>" format. 'P' ends the simulation with exit code 0, 'F' with 1
 *   (system control EXIT; no effect on the board).
 */
#ifndef REPORT_H
#define REPORT_H

#ifdef HORNET_LEGACY

#define DEBUG_IF_ADDR 0x10008010
#define DEBUG_REG     ((volatile char *)DEBUG_IF_ADDR)

static inline void report(char code)
{
  *DEBUG_REG = code;
}

#else

#include <stdio.h>
#include "hornet.h"
#include "uart.h"

#define REPORT_MAX 32

static unsigned long report_cycle[REPORT_MAX];   /* low 32 bits; newlib-nano printf has no %llu */
static char report_code[REPORT_MAX];
static unsigned int report_n;

static inline void report(char code)
{
  unsigned int i;

  if(report_n < REPORT_MAX) {
    report_cycle[report_n] = (unsigned long)hornet_cycles();
    report_code[report_n] = code;
    report_n++;
  }
  if(code != 'P' && code != 'F')
    return;

  for(i = 0; i < report_n; i++)
    printf("    cycle %lu : %d\n", report_cycle[i], report_code[i]);
  printf(code == 'P' ? "TEST PASSED\n" : "TEST FAILED\n");
  fflush(stdout);
  uart_wait_tx_idle(&uart0);   /* the simulation ends on EXIT; let the last line go out */
  hornet_exit(code == 'P' ? 0 : 1);
}

#endif

#endif
