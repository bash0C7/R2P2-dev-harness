/*
 * QEMU BLE event-path rig for picoruby PR #427.
 *
 * Compiled only when PICORUBY_QEMU_EVQ_RIG is defined (see
 * r2p2-esp32.patch). A FreeRTOS task stands in for the NimBLE host
 * task and injects synthetic GAP events into picoruby-ble's ring
 * buffer; tools/esp32/evq_verdict.rb judges the resulting log.
 *
 * Log tokens (exact format matters — the verdict greps them):
 *   [rig] inject done n=<n>       all events inserted (Ruby logs seq/tin/t)
 *   [rig] FOREIGN_PUSH <who>      Ruby queue touched off the VM thread
 *
 * Two phases:
 *   phase 1: seq 1..20  every 500 ms — latency + FOREIGN_PUSH evidence
 *   phase 2: seq 21..60 every 10 ms  — ring overflow (EVQ_DEPTH=32)
 *            evidence: pre-fix, a 1 Hz heartbeat-paced drain cannot keep
 *            up, so the ring drops the oldest events (lost seqs)
 */
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_timer.h"

extern void picoruby_nimble_enqueue_event(const uint8_t *pkt, uint16_t len, bool coalesce_adv);
extern int picoruby_nimble_enqueue_write(uint16_t ruby_handle, const uint8_t *data, uint16_t len);

#ifdef PICORUBY_QEMU_EVQ_FLOOD
#define FLOOD_HANDLE 0x43
#define FLOOD_PAYLOAD_LEN 128
#define FLOOD_COUNT 500
#define FLOOD_SPACING_MS 2
#endif

volatile int rig_fault_write = 0;

void
rig_log_fault_write(void)
{
  printf("[rig] FAULT write\n");
}

static TaskHandle_t rig_vm_task = NULL;
static volatile bool rig_power_on = false;

/* Called from BLE_init (VM thread) via the patched picoruby_nimble_start. */
static void
rig_record_vm_task(void)
{
  rig_vm_task = xTaskGetCurrentTaskHandle();
}

/* Called from the patched BLE_hci_power_control(1). */
void
rig_notify_power_on(void)
{
  rig_power_on = true;
}

/* Patched into BLE_push_event / BLE_heartbeat (both VMs). */
void
rig_check_vm_thread(const char *who)
{
  if (rig_vm_task != NULL && xTaskGetCurrentTaskHandle() != rig_vm_task) {
    printf("[rig] FOREIGN_PUSH %s\n", who);
  }
}

/* GAP_EVENT_ADVERTISING_REPORT in the layout ble_advertising_report.rb
 * parses: [0]=0xda [1]=len-2 [2]=event_type [3]=addr_type [4..9]=addr
 * [10]=rssi [11]=data_length [12..]=AD structures. AD carries one
 * complete-local-name entry: "RIG-<seq>". */
static uint16_t
rig_build_adv(uint8_t *p, int seq, uint32_t tin_ms)
{
  char name[24];
  int name_len = snprintf(name, sizeof(name), "RIG-%03d-%08lu", seq,
                           (unsigned long)tin_ms);
  p[0] = 0xda;
  p[2] = 0x00;
  p[3] = 0x00;
  memset(p + 4, 0xA5, 6);
  p[9] = (uint8_t)seq;
  p[10] = 0xC0;
  p[11] = (uint8_t)(2 + name_len);
  p[12] = (uint8_t)(1 + name_len);
  p[13] = 0x09; /* complete local name */
  memcpy(p + 14, name, name_len);
  uint16_t total = (uint16_t)(14 + name_len);
  p[1] = (uint8_t)(total - 2);
  return total;
}

static void
rig_inject(int seq)
{
  static uint8_t adv[32];
  uint32_t tin_ms = (uint32_t)(esp_timer_get_time() / 1000);
  uint16_t len = rig_build_adv(adv, seq, tin_ms);
  picoruby_nimble_enqueue_event(adv, len, false);
}

static void
rig_task(void *arg)
{
  (void)arg;
  while (!rig_power_on) {
    vTaskDelay(pdMS_TO_TICKS(100));
  }
  /* Let Ruby consume BTSTACK_EVENT_STATE(working) — synthesized by
   * BLE_hci_power_control — and enter :TC_W4_SCAN_RESULT; adv reports
   * that arrive earlier are dropped by packet_callback by design. */
  vTaskDelay(pdMS_TO_TICKS(2000));
  static const uint8_t state_working[] = { 0x60, 0x01, 0x02 };
  picoruby_nimble_enqueue_event(state_working, sizeof(state_working), false);

  rig_fault_write = 1;
  printf("[rig] write enq A\n");
  picoruby_nimble_enqueue_write(0x42, (const uint8_t *)"A", 1);
  vTaskDelay(pdMS_TO_TICKS(500));
  printf("[rig] write enq B\n");
  picoruby_nimble_enqueue_write(0x42, (const uint8_t *)"B", 1);
  vTaskDelay(pdMS_TO_TICKS(500));

  for (int seq = 1; seq <= 20; seq++) {
    rig_inject(seq);
    vTaskDelay(pdMS_TO_TICKS(500));
  }
  for (int seq = 21; seq <= 60; seq++) {
    rig_inject(seq);
    vTaskDelay(pdMS_TO_TICKS(10));
  }
  printf("[rig] inject done n=60\n");

#ifdef PICORUBY_QEMU_EVQ_FLOOD
  static uint8_t flood_payload[FLOOD_PAYLOAD_LEN];
  memset(flood_payload, 0x5a, sizeof(flood_payload));
  for (int i = 0; i < FLOOD_COUNT; i++) {
    picoruby_nimble_enqueue_write(FLOOD_HANDLE, flood_payload, sizeof(flood_payload));
    vTaskDelay(pdMS_TO_TICKS(FLOOD_SPACING_MS));
  }
  printf("[rig] flood done n=%d\n", FLOOD_COUNT);
#endif

  vTaskDelete(NULL);
}

/* Called from the patched picoruby_nimble_start, on the VM thread. */
void
rig_start(void)
{
  static bool started = false;
  rig_record_vm_task();
  if (started) return;
  started = true;
  xTaskCreate(rig_task, "evq_rig", 4096, NULL, 5, NULL);
}
