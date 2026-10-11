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
 *
 * Optional phase, PICORUBY_QEMU_EVQ_LIMITS (judged by judge_limits):
 *   [rig] burst accepted=<n> refused=<m> first_refused=<seq|0> budget=<b> entry=<e>
 *                                         what the ring answered to the burst (port
 *                                         with the byte ring only); budget is
 *                                         PICORUBY_BLE_EVQ_BYTES, entry the bytes one
 *                                         injected event takes (2 + packet)
 *   [rig] burst done first=<a> last=<b>   non-adv events a..b enqueued back to back
 *   [rig] notify injected len=<n>         NOTIFY_RX with an n-byte value handed
 *                                         to picoruby_ble_gap_event
 *   [rig] limits done                     end of the limits phase
 *   L1: seq 101..180 with no delay — overflows the event ring (the overlay sets
 *       PICORUBY_BLE_EVQ_BYTES=1024: 31 entries of 32 bytes fit beside the
 *       11-byte completion reserve; the 32-deep ring of the old port overflows too)
 *   L2: notifications of 93 and 200 bytes — longer than the old 92-byte cap
 *   [rig] control done first=<a> last=<b> h1=<n> h2=<n>
 *                                         L3 inserted (handles in decimal)
 *   [rig] cansend injected n=<n> con_handle=<h>
 *                                         L4 calls made; con_handle (decimal)
 *                                         as read just before them
 *   [rig] extra state injected            the extra BTSTACK_STATE(working) is
 *                                         enqueued next; Ruby STATE lines
 *                                         before this one come from the port
 *   L3: DISCONNECTION_COMPLETE h1, burst seq 201..260, DISCONNECTION_COMPLETE h2,
 *       back to back, through picoruby_ble_gap_event and rig_inject
 *   L4: BLE_peripheral_request_can_send_now_event() called back to back with
 *       no connection
 *   L5: two descriptor-discovery procedures driven through the port's own
 *       disc_dsc_cb (rig_gatt_dsc_result / rig_gatt_dsc_done, compiled into
 *       ble.c by radio_stub.patch): A with 3 results, B with 100 results that
 *       overflow the ring; each ends with the completion the port builds
 *   [rig] proc <A|B> injected results=<n> handle_first=<h>
 *   [rig] proc <A|B> done
 *
 * Optional case, PICORUBY_QEMU_EVQ_POWER (judged by judge_power): the device
 * program (rigapp_power.rb) drives hci_power_control through its steps and
 * the injector task stays idle. The rig acts only through rig_power_control_entry(),
 * called from the patched BLE_hci_power_control before the port does anything for the
 * call, and through the NimBLE stubs (rig_nimble_stubs.c), which log every call the
 * port makes to the host. The entry hook injects, before the power-on call numbered
 * POWER_NESTED_CALL (the nested one, step 7):
 *   [rig] power inject disc handle=<n> call=<k>
 *                                         a DISCONNECTION_COMPLETE for handle n
 *                                         enqueued just before the k-th power-on
 *                                         call (the nested one, step 7)
 *
 * Optional case, PICORUBY_QEMU_EVQ_RESYNC (judged by judge_resync): the NimBLE
 * host does not run under QEMU, so the rig plays it for the sync handshake of
 * picoruby_nimble_start, which otherwise runs as written. rig_host_start()
 * replaces nimble_port_freertos_init(): a task calls the port's sync_cb after
 * 200 ms; in the first session it then calls reset_cb and sync_cb again, as
 * the host does after a controller reset. ble_gap_adv_start is answered by
 * the rig: 0 when the rig host is synced, BLE_HS_ENOTSYNCED when it is not.
 *   [rig] host sync_cb session=<n>        sync_cb called
 *   [rig] host reset_cb session=<n>       reset_cb called
 *   [rig] host resync done                the forced reset and re-sync are over
 *   [rig] ble_gap_adv_start rc=<rc> host_synced=<0|1>
 *                                         what the port asked of the host
 *
 *   A marker event {0xFE, 1, n} is enqueued after L3 (n=1) and after L4
 *   (n=2) and after L5 (n=3), once the ring has drained; the device program logs it as
 *   "[rigapp] mark <n>".
 */
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_timer.h"

#ifdef PICORUBY_QEMU_EVQ_OLD_PORT
/* port at 7529064b: void, with the advertising-report coalescing flag */
extern void picoruby_nimble_enqueue_event(const uint8_t *pkt, uint16_t len, bool coalesce_adv);
static int
rig_enqueue(const uint8_t *pkt, uint16_t len)
{
  picoruby_nimble_enqueue_event(pkt, len, false);
  return 0;
}
#else
extern int picoruby_nimble_enqueue_event(const uint8_t *pkt, uint16_t len);
static int
rig_enqueue(const uint8_t *pkt, uint16_t len)
{
  return picoruby_nimble_enqueue_event(pkt, len);
}
#endif
extern void rig_stub_install_npl(void);
/* absent from the ports that predate the advertising callout */
extern void picoruby_ble_peripheral_rearm_init(void) __attribute__((weak));
extern int picoruby_nimble_enqueue_write(uint16_t ruby_handle, const uint8_t *data, uint16_t len);
#ifndef PICORUBY_QEMU_EVQ_OLD_PORT
extern int picoruby_nimble_set_write_handles(const uint16_t *handles, size_t count);
#endif

#if defined(PICORUBY_QEMU_EVQ_LIMITS) || defined(PICORUBY_QEMU_EVQ_POWER) || defined(PICORUBY_QEMU_EVQ_RESYNC)
/* Same includes as ports/esp32/ble.c: the notification path is fed with a
 * struct ble_gap_event carrying an os_mbuf. */
#include "host/ble_hs.h"
#include "host/ble_gap.h"
#include "os/os_mbuf.h"
#include "ble_common.h"
#endif

#ifdef PICORUBY_QEMU_EVQ_POWER
/* rigapp_power.rb powers on in steps 1, 4, 6 and 7; step 7 is the nested one. */
#define POWER_NESTED_CALL 4
#define POWER_LATE_DISCONNECT_MS 1300
/* the second sleep call (step 10) and the fifth power-off call (step 14) arm the stubbed host to raise
 * the terminated link's disconnect late: 1300 ms after the sleep, 600 ms after the power-off. */
#define POWER_LATE_SLEEP_CALL 2
#define POWER_LATE_OFF_CALL 5
#define POWER_LATE_OFF_DISCONNECT_MS 600
extern void rig_stub_late_disconnect(int ms);
#define POWER_DISC_HANDLE 0x0033
#endif

#ifdef PICORUBY_QEMU_EVQ_LIMITS

#define LIMITS_BURST_FIRST 101
#define LIMITS_BURST_LAST 180
#define LIMITS_NOTIFY_MAX 200
#define LIMITS_NOTIFY_CONN 1
#define LIMITS_NOTIFY_ATTR 0x30
#define CONTROL_BURST_FIRST 201
#define CONTROL_BURST_LAST 260
#define CONTROL_HANDLE_FIRST 0x0011
#define CONTROL_HANDLE_LAST 0x0022
#define CAN_SEND_CALLS 5
#define MARK_EVENT 0xFE

extern void BLE_peripheral_request_can_send_now_event(void);
/* compiled into ble.c by radio_stub.patch */
extern void rig_gatt_dsc_result(uint16_t conn, uint16_t handle);
extern void rig_gatt_dsc_done(uint16_t conn);
#define PROC_CONN 1
#define PROC_A_RESULTS 3
#define PROC_A_HANDLE_FIRST 1
#define PROC_B_RESULTS 100
#define PROC_B_HANDLE_FIRST 101
#define RIG_TASK_STACK 6144
#else
#define RIG_TASK_STACK 4096
#endif

#ifdef PICORUBY_QEMU_EVQ_FLOOD
#define FLOOD_HANDLE 0x43
#define FLOOD_PAYLOAD_LEN 128
#define FLOOD_COUNT 500
#define FLOOD_PROBE_EVERY 10
#define WLAT_HANDLE 0x44
#ifndef FLOOD_SPACING_MS
#define FLOOD_SPACING_MS 2
#endif
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

static int
rig_inject(int seq)
{
  static uint8_t adv[32];
  uint32_t tin_ms = (uint32_t)(esp_timer_get_time() / 1000);
  uint16_t len = rig_build_adv(adv, seq, tin_ms);
  return rig_enqueue(adv, len);
}

#if defined(PICORUBY_QEMU_EVQ_LIMITS) || defined(PICORUBY_QEMU_EVQ_POWER)
static struct ble_gap_event rig_gap_event;

static void
rig_inject_disconnect(uint16_t handle)
{
  memset(&rig_gap_event, 0, sizeof(rig_gap_event));
  rig_gap_event.type = BLE_GAP_EVENT_DISCONNECT;
  rig_gap_event.disconnect.reason = 0x13;
  rig_gap_event.disconnect.conn.conn_handle = handle;
  picoruby_ble_gap_event(&rig_gap_event, NULL);
}
#endif

#ifdef PICORUBY_QEMU_EVQ_LIMITS
/* One os_mbuf as NimBLE hands it to the GAP callback, built by hand: the
 * host is not running, so no mbuf pool exists. The layout is what
 * OS_MBUF_PKTHDR / OS_MBUF_PKTLEN / os_mbuf_copydata read: struct os_mbuf,
 * then struct os_mbuf_pkthdr (OS_MBUF_PKTHDR = &om_data + sizeof(struct
 * os_mbuf)), then the data (OS_MBUF_USRHDR). A single mbuf: om_next stays
 * NULL, so omp_len == om_len. */
static union {
  struct os_mbuf om;
  uint8_t raw[sizeof(struct os_mbuf) + sizeof(struct os_mbuf_pkthdr) + LIMITS_NOTIFY_MAX];
} rig_mbuf;

static void
rig_inject_notify(uint16_t len)
{
  struct os_mbuf *om = &rig_mbuf.om;
  memset(&rig_mbuf, 0, sizeof(rig_mbuf));
  uint8_t *data = (uint8_t *)OS_MBUF_USRHDR(om);
  for (uint16_t i = 0; i < len; i++) data[i] = (uint8_t)(i & 0xff);
  om->om_data = data;
  om->om_len = len;
  om->om_pkthdr_len = sizeof(struct os_mbuf_pkthdr);
  OS_MBUF_PKTHDR(om)->omp_len = len;

  memset(&rig_gap_event, 0, sizeof(rig_gap_event));
  rig_gap_event.type = BLE_GAP_EVENT_NOTIFY_RX;
  rig_gap_event.notify_rx.om = om;
  rig_gap_event.notify_rx.attr_handle = LIMITS_NOTIFY_ATTR;
  rig_gap_event.notify_rx.conn_handle = LIMITS_NOTIFY_CONN;
  rig_gap_event.notify_rx.indication = 0;
  picoruby_ble_gap_event(&rig_gap_event, NULL);
  printf("[rig] notify injected len=%u\n", (unsigned)len);
}

static void
rig_inject_mark(uint8_t n)
{
  const uint8_t mark[] = { MARK_EVENT, 1, n };
  rig_enqueue(mark, sizeof(mark));
}

/* One descriptor-discovery procedure as the host would run it: results through
 * the port's disc_dsc_cb, then the callback's end-of-procedure call. */
static void
rig_procedure(char name, int results, int handle_first)
{
  for (int i = 0; i < results; i++) {
    rig_gatt_dsc_result(PROC_CONN, (uint16_t)(handle_first + i));
  }
  rig_gatt_dsc_done(PROC_CONN);
  vTaskDelay(pdMS_TO_TICKS(1000));
  printf("[rig] proc %c injected results=%d handle_first=%d\n", name, results, handle_first);
  printf("[rig] proc %c done\n", name);
}

static void
rig_limits(void)
{
  /* L1: no delay between inserts, so the ring overflows. The port with the byte
   * ring answers each insert; the judge compares what it accepted with what
   * reached Ruby. */
  int accepted = 0, refused = 0, first_refused = 0;
  for (int seq = LIMITS_BURST_FIRST; seq <= LIMITS_BURST_LAST; seq++) {
    if (rig_inject(seq) == 0) {
      accepted++;
    } else {
      refused++;
      if (first_refused == 0) first_refused = seq;
    }
  }
  /* Both tasks write to the same UART: a rig line printed while the pump is
   * still handing events to Ruby would cut one of Ruby's lines in half. */
  vTaskDelay(pdMS_TO_TICKS(1000));
#ifndef PICORUBY_QEMU_EVQ_OLD_PORT
  {
    uint8_t probe[32];
    int entry = 2 + (int)rig_build_adv(probe, LIMITS_BURST_FIRST, 0);
    printf("[rig] burst accepted=%d refused=%d first_refused=%d budget=%d entry=%d\n",
           accepted, refused, first_refused, PICORUBY_BLE_EVQ_BYTES, entry);
  }
#endif
  printf("[rig] burst done first=%d last=%d\n", LIMITS_BURST_FIRST, LIMITS_BURST_LAST);
  vTaskDelay(pdMS_TO_TICKS(2000));

  /* L2: values longer than the 92-byte cap of the event packet. */
  rig_inject_notify(93);
  vTaskDelay(pdMS_TO_TICKS(300));
  rig_inject_notify(200);
  vTaskDelay(pdMS_TO_TICKS(3000));

  /* L3: control events around a burst that overflows the ring. */
  rig_inject_disconnect(CONTROL_HANDLE_FIRST);
  for (int seq = CONTROL_BURST_FIRST; seq <= CONTROL_BURST_LAST; seq++) {
    rig_inject(seq);
  }
  rig_inject_disconnect(CONTROL_HANDLE_LAST);
  vTaskDelay(pdMS_TO_TICKS(1000));
  printf("[rig] control done first=%d last=%d h1=%d h2=%d\n",
         CONTROL_BURST_FIRST, CONTROL_BURST_LAST, CONTROL_HANDLE_FIRST, CONTROL_HANDLE_LAST);
  vTaskDelay(pdMS_TO_TICKS(2000));
  rig_inject_mark(1);
  vTaskDelay(pdMS_TO_TICKS(1000));

  /* L4: nothing in the rig connects, so con_handle is still 0xffff. */
  unsigned handle_before = (unsigned)con_handle;
  for (int i = 0; i < CAN_SEND_CALLS; i++) {
    BLE_peripheral_request_can_send_now_event();
  }
  printf("[rig] cansend injected n=%d con_handle=%u\n", CAN_SEND_CALLS, handle_before);
  vTaskDelay(pdMS_TO_TICKS(3000));
  rig_inject_mark(2);
  vTaskDelay(pdMS_TO_TICKS(1000));

  /* L5: a procedure whose results fit, then one whose results overflow the ring. */
  rig_procedure('A', PROC_A_RESULTS, PROC_A_HANDLE_FIRST);
  vTaskDelay(pdMS_TO_TICKS(2000));
  rig_procedure('B', PROC_B_RESULTS, PROC_B_HANDLE_FIRST);
  vTaskDelay(pdMS_TO_TICKS(2000));
  rig_inject_mark(3);
  vTaskDelay(pdMS_TO_TICKS(1000));
  printf("[rig] limits done\n");
}
#endif

#ifdef PICORUBY_QEMU_EVQ_RESYNC
#define RESYNC_SYNC_MS 200
#define RESYNC_RESET_AFTER_MS 300
#define RESYNC_RESYNC_AFTER_MS 100
#define RESYNC_RESET_REASON 0x13

static volatile bool rig_host_synced = false;
static volatile int rig_host_epoch = 0; /* session whose host task may still call back; 0 = none */
static int rig_host_sessions = 0;
static void (*rig_sync_cb)(void);
static void (*rig_reset_cb)(int);

static bool
rig_host_alive(int session)
{
  return rig_host_epoch == session;
}

static void
rig_host_task(void *arg)
{
  int session = (int)(intptr_t)arg;
  vTaskDelay(pdMS_TO_TICKS(RESYNC_SYNC_MS));
  if (rig_host_alive(session)) {
    rig_host_synced = true;
    printf("[rig] host sync_cb session=%d\n", session);
    rig_sync_cb();
    if (session == 1) {
      vTaskDelay(pdMS_TO_TICKS(RESYNC_RESET_AFTER_MS));
      if (rig_host_alive(session)) {
        rig_host_synced = false;
        printf("[rig] host reset_cb session=%d\n", session);
        rig_reset_cb(RESYNC_RESET_REASON);
        vTaskDelay(pdMS_TO_TICKS(RESYNC_RESYNC_AFTER_MS));
        if (rig_host_alive(session)) {
          rig_host_synced = true;
          printf("[rig] host sync_cb session=%d\n", session);
          rig_sync_cb();
          printf("[rig] host resync done\n");
        }
      }
    }
  }
  vTaskDelete(NULL);
}

/* Called from the patched picoruby_nimble_start in place of nimble_port_freertos_init. */
void
rig_host_start(void (*sync_cb)(void), void (*reset_cb)(int))
{
  rig_sync_cb = sync_cb;
  rig_reset_cb = reset_cb;
  rig_host_synced = false;
  rig_host_epoch = ++rig_host_sessions;
  xTaskCreate(rig_host_task, "evq_host", 4096, (void *)(intptr_t)rig_host_sessions, 5, NULL);
}

/* The rig's answer in place of ble_gap_adv_start (patched into adv_start). */
int
rig_gap_adv_start(void)
{
  int rc = rig_host_synced ? 0 : BLE_HS_ENOTSYNCED;
  printf("[rig] ble_gap_adv_start rc=%d host_synced=%d\n", rc, (int)rig_host_synced);
  return rc;
}
#endif

/* Called from the patched picoruby_nimble_stop: the host the port stopped must not call back. */
void
rig_host_stopped(void)
{
#ifdef PICORUBY_QEMU_EVQ_RESYNC
  rig_host_epoch = 0;
  rig_host_synced = false;
#endif
}

/* Called from the patched BLE_hci_power_control, on the VM thread, before the
 * port does anything for the call. In the power case the POWER_NESTED_CALL-th
 * power-on call (step 7, power-on while on) gets one event into the ring first, and
 * a sleep or power-off call arms the stubbed host to deliver the disconnect of the
 * terminated link late (see POWER_LATE_*). */
void
rig_power_control_entry(uint8_t power_mode)
{
  if (power_mode == 1) rig_power_on = true;
#ifdef PICORUBY_QEMU_EVQ_POWER
  static int calls = 0;
  if (power_mode == 1 && ++calls == POWER_NESTED_CALL) {
    rig_inject_disconnect(POWER_DISC_HANDLE);
    printf("[rig] power inject disc handle=%d call=%d\n", POWER_DISC_HANDLE, calls);
  }
  static int sleeps = 0;
  static int offs = 0;
  if (power_mode == 2 && ++sleeps == POWER_LATE_SLEEP_CALL) rig_stub_late_disconnect(POWER_LATE_DISCONNECT_MS);
  if (power_mode == 0 && ++offs == POWER_LATE_OFF_CALL) rig_stub_late_disconnect(POWER_LATE_OFF_DISCONNECT_MS);
#endif
}

static void
rig_task(void *arg)
{
  (void)arg;
#if defined(PICORUBY_QEMU_EVQ_POWER) || defined(PICORUBY_QEMU_EVQ_RESYNC)
  /* The device program drives this case; nothing to inject from here. */
  vTaskDelete(NULL);
  return;
#endif
  while (!rig_power_on) {
    vTaskDelay(pdMS_TO_TICKS(100));
  }
  /* Let Ruby consume BTSTACK_EVENT_STATE(working) — synthesized by
   * BLE_hci_power_control — and enter :TC_W4_SCAN_RESULT; adv reports
   * that arrive earlier are dropped by packet_callback by design. */
  vTaskDelay(pdMS_TO_TICKS(2000));
  static const uint8_t state_working[] = { 0x60, 0x01, 0x02 };
#ifdef PICORUBY_QEMU_EVQ_LIMITS
  printf("[rig] extra state injected\n");
#endif
  rig_enqueue(state_working, sizeof(state_working));

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

  for (int i = 0; i < 20; i++) {
    char tin[12];
    int n = snprintf(tin, sizeof(tin), "%lu", (unsigned long)(esp_timer_get_time() / 1000));
    picoruby_nimble_enqueue_write(0x44, (const uint8_t *)tin, (uint16_t)n);
    vTaskDelay(pdMS_TO_TICKS(100));
  }
  printf("[rig] wlat done n=20\n");

#ifdef PICORUBY_QEMU_EVQ_FLOOD
  static uint8_t flood_payload[FLOOD_PAYLOAD_LEN];
  memset(flood_payload, 0x5a, sizeof(flood_payload));
  int rejected = 0;
  int probes = 0;
  uint32_t begin_ms = (uint32_t)(esp_timer_get_time() / 1000);
  for (int i = 0; i < FLOOD_COUNT; i++) {
    if (picoruby_nimble_enqueue_write(FLOOD_HANDLE, flood_payload, sizeof(flood_payload)) != 0) rejected++;
    if (i % FLOOD_PROBE_EVERY == FLOOD_PROBE_EVERY / 2) {
      /* a write to a second handle while the first is saturated: it must not wait for the flood */
      char tin[12];
      int n = snprintf(tin, sizeof(tin), "%lu", (unsigned long)(esp_timer_get_time() / 1000));
      if (picoruby_nimble_enqueue_write(WLAT_HANDLE, (const uint8_t *)tin, (uint16_t)n) == 0) probes++;
    }
    vTaskDelay(pdMS_TO_TICKS(FLOOD_SPACING_MS));
  }
  uint32_t end_ms = (uint32_t)(esp_timer_get_time() / 1000);
  vTaskDelay(pdMS_TO_TICKS(1000)); /* let Ruby finish its own lines before ours */
  printf("[rig] flood done n=%d rejected=%d begin=%lu end=%lu probes=%d\n", FLOOD_COUNT, rejected,
         (unsigned long)begin_ms, (unsigned long)end_ms, probes);
#endif

#ifdef PICORUBY_QEMU_EVQ_LIMITS
  rig_limits();
#endif

  vTaskDelete(NULL);
}

/* Called from the patched picoruby_nimble_start, on the VM thread. */
void
rig_start(void)
{
  static bool started = false;
  rig_record_vm_task();
  rig_stub_install_npl();
  if (picoruby_ble_peripheral_rearm_init != NULL) picoruby_ble_peripheral_rearm_init();
#ifndef PICORUBY_QEMU_EVQ_OLD_PORT
  {
    /* the injector queues writes to these handles; they get rows the way the port builds its own */
    static const uint16_t rig_handles[] = { 0x42, 0x43, 0x44 };
    picoruby_nimble_set_write_handles(rig_handles, sizeof(rig_handles) / sizeof(rig_handles[0]));
  }
#endif
  if (started) return;
  started = true;
  xTaskCreate(rig_task, "evq_rig", RIG_TASK_STACK, NULL, 5, NULL);
}
