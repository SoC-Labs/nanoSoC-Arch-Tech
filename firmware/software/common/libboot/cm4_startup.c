/*----------------------------------------------------------------------------
 * Minimal Cortex-M4 startup (vector table + Reset_Handler) for boot stages.
 * Copyright 2026, SoC Labs (www.soclabs.org)
 *----------------------------------------------------------------------------
 * Shared by every staged image (bootrom, spl, ...). The linker script places
 * .isr_vector at the stage's origin; the bootrom runs from its reset alias at
 * 0x0, later stages from their VTOR base set by boot_handoff(). Only the system
 * exception vectors are populated (boot stages take no peripheral IRQs).
 */
#include <stdint.h>

extern uint32_t _sidata, _sdata, _edata, _sbss, _ebss, _estack;
extern int main(void);

void Reset_Handler(void);
void Default_Handler(void);
__attribute__((weak)) void SystemInit(void) { }

/* weak system-exception handlers -> Default_Handler */
#define ALIAS __attribute__((weak, alias("Default_Handler")))
void NMI_Handler(void)        ALIAS;
void HardFault_Handler(void)  ALIAS;
void MemManage_Handler(void)  ALIAS;
void BusFault_Handler(void)   ALIAS;
void UsageFault_Handler(void) ALIAS;
void SVC_Handler(void)        ALIAS;
void DebugMon_Handler(void)   ALIAS;
void PendSV_Handler(void)     ALIAS;
void SysTick_Handler(void)    ALIAS;

/* Weak external NVIC interrupt handlers (vectors 16..31 = IRQ0..IRQ15), all
 * default to Default_Handler. Firmware overrides the ones it uses by defining a
 * strong symbol of the same name (e.g. Interrupt0_Handler for the IPC mailbox
 * doorbell on NVIC IRQ0). Extend this list if more device IRQs are wired. */
void Interrupt0_Handler(void)  ALIAS;  void Interrupt1_Handler(void)  ALIAS;
void Interrupt2_Handler(void)  ALIAS;  void Interrupt3_Handler(void)  ALIAS;
void Interrupt4_Handler(void)  ALIAS;  void Interrupt5_Handler(void)  ALIAS;
void Interrupt6_Handler(void)  ALIAS;  void Interrupt7_Handler(void)  ALIAS;
void Interrupt8_Handler(void)  ALIAS;  void Interrupt9_Handler(void)  ALIAS;
void Interrupt10_Handler(void) ALIAS;  void Interrupt11_Handler(void) ALIAS;
void Interrupt12_Handler(void) ALIAS;  void Interrupt13_Handler(void) ALIAS;
void Interrupt14_Handler(void) ALIAS;  void Interrupt15_Handler(void) ALIAS;

/* Cortex-M system vector table (16) + 16 external NVIC vectors (IRQ0..IRQ15). */
__attribute__((section(".isr_vector"), used))
void (* const g_vectors[32])(void) = {
    (void (*)(void))(&_estack),  /* 0  initial MSP            */
    Reset_Handler,               /* 1  reset                  */
    NMI_Handler,                 /* 2                          */
    HardFault_Handler,           /* 3                          */
    MemManage_Handler,           /* 4                          */
    BusFault_Handler,            /* 5                          */
    UsageFault_Handler,          /* 6                          */
    0, 0, 0, 0,                  /* 7-10 reserved             */
    SVC_Handler,                 /* 11                         */
    DebugMon_Handler,            /* 12                         */
    0,                           /* 13 reserved               */
    PendSV_Handler,              /* 14                         */
    SysTick_Handler,             /* 15                         */
    Interrupt0_Handler,  Interrupt1_Handler,  Interrupt2_Handler,  Interrupt3_Handler,
    Interrupt4_Handler,  Interrupt5_Handler,  Interrupt6_Handler,  Interrupt7_Handler,
    Interrupt8_Handler,  Interrupt9_Handler,  Interrupt10_Handler, Interrupt11_Handler,
    Interrupt12_Handler, Interrupt13_Handler, Interrupt14_Handler, Interrupt15_Handler,
};

void Reset_Handler(void)
{
    /* copy .data (LMA -> VMA) */
    uint32_t *src = &_sidata, *dst = &_sdata;
    while (dst < &_edata) *dst++ = *src++;
    /* zero .bss */
    for (dst = &_sbss; dst < &_ebss; ) *dst++ = 0u;

    SystemInit();
    (void)main();
    for (;;) { }   /* a boot stage hands off via boot_handoff(); never returns here */
}

void Default_Handler(void) { for (;;) { } }
