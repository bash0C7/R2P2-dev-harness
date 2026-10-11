/*
 * NimBLE call stubs of the qemu-ble-evq rig.
 *
 * The NimBLE host does not run under QEMU: there is no controller, and a
 * ble_gap_* call dereferences state the host never built. r2p2-esp32.patch
 * renames the calls the port makes (-Dble_gap_adv_stop=rig_ble_gap_adv_stop
 * and so on) for the port sources and this file only, so everything else in
 * the port runs as it is and these functions answer in place of the host. They
 * are defined here under the NimBLE names; the same renaming turns the
 * definitions into the rig_ ones.
 *
 * Every stubbed call logs one line, in call order, from the thread that made it:
 *   [rig] nimble <name> [args] power=<n>
 * power is the port's power state at the call (0 off, 1 on, 2 sleeping, 255
 * when the port under test has none). The judge reads the order of these lines.
 *
 * What the stubs model of the host:
 *   advertising   active after ble_gap_adv_start returned 0, until ble_gap_adv_stop
 *   discovery     active after ble_gap_disc returned 0, until ble_gap_disc_cancel
 *   connect       ble_gap_connect starts an attempt that stays pending; a peer whose
 *                 address starts with 0xBB answers after RIG_CONNECT_DELAY_MS with a
 *                 CONNECT event for handle RIG_LINK_HANDLE from a task of its own
 *                 (the host task's role); any other peer never answers.
 *                 ble_gap_conn_cancel ends a pending attempt (the host would then raise
 *                 CONNECT with status BLE_HS_EAPP; the rig never does, which is what
 *                 lets the halting deadline run).
 *   terminate     ble_gap_terminate answers 0 and the DISCONNECT never comes, unless
 *                 rig_stub_late_disconnect armed it: then the DISCONNECT of the
 *                 terminated link (reason BLE_HS_HCI_ERR(0x16)) is raised from a task of
 *                 its own that many milliseconds later, the real disconnect arriving
 *                 after the port gave up waiting for it.
 */
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "host/ble_hs.h"
#include "host/ble_gap.h"
#include "host/util/util.h"

#include "ble_common.h"

#define RIG_LINK_HANDLE 0x0033
#define RIG_CONNECT_DELAY_MS 30
#define RIG_ANSWERING_PEER 0xBB

extern volatile uint8_t ble_power __attribute__((weak));

#ifdef PICORUBY_QEMU_EVQ_RESYNC
extern int rig_gap_adv_start(void);
#endif

static volatile bool adv_active = false;
static volatile bool disc_active = false;
static volatile bool conn_pending = false;
static volatile int late_disconnect_ms = 0;

void
rig_stub_late_disconnect(int ms)
{
  late_disconnect_ms = ms;
}

static void
rig_late_disconnect_task(void *arg)
{
  const uint16_t handle = (uint16_t)(uintptr_t)arg;
  vTaskDelay(pdMS_TO_TICKS(late_disconnect_ms));
  late_disconnect_ms = 0;
  struct ble_gap_event ev;
  memset(&ev, 0, sizeof(ev));
  ev.type = BLE_GAP_EVENT_DISCONNECT;
  ev.disconnect.reason = BLE_HS_HCI_ERR(0x16);
  ev.disconnect.conn.conn_handle = handle;
  printf("[rig] host DISCONNECT handle=%u\n", (unsigned)handle);
  picoruby_ble_gap_event(&ev, NULL);
  vTaskDelete(NULL);
}

static unsigned
power_now(void)
{
  return &ble_power != NULL ? ble_power : 255;
}

#define CALL_LOG(name) printf("[rig] nimble " name " power=%u\n", power_now())

int
ble_gap_adv_stop(void)
{
  CALL_LOG("ble_gap_adv_stop");
  bool was = adv_active;
  adv_active = false;
  return was ? 0 : BLE_HS_EALREADY;
}

int
ble_gap_adv_set_data(const uint8_t *data, int data_len)
{
  (void)data;
  (void)data_len;
  CALL_LOG("ble_gap_adv_set_data");
  return 0;
}

int
ble_gap_adv_start(uint8_t own_addr_type, const ble_addr_t *direct_addr,
                  int32_t duration_ms,
                  const struct ble_gap_adv_params *adv_params,
                  ble_gap_event_fn *cb, void *cb_arg)
{
  (void)own_addr_type;
  (void)direct_addr;
  (void)duration_ms;
  (void)adv_params;
  (void)cb;
  (void)cb_arg;
#ifdef PICORUBY_QEMU_EVQ_RESYNC
  return rig_gap_adv_start();
#else
  CALL_LOG("ble_gap_adv_start");
  adv_active = true;
  return 0;
#endif
}

int
ble_gap_adv_active(void)
{
  return adv_active;
}

int
ble_gap_terminate(uint16_t conn_handle, uint8_t hci_reason)
{
  printf("[rig] nimble ble_gap_terminate handle=%u reason=0x%02x power=%u\n",
         (unsigned)conn_handle, (unsigned)hci_reason, power_now());
  if (late_disconnect_ms > 0) {
    xTaskCreate(rig_late_disconnect_task, "evq_late", 6144, (void *)(uintptr_t)conn_handle, 5, NULL);
  }
  return 0;
}

int
ble_gap_conn_active(void)
{
  printf("[rig] nimble ble_gap_conn_active -> %d power=%u\n", (int)conn_pending, power_now());
  return conn_pending;
}

int
ble_gap_conn_cancel(void)
{
  CALL_LOG("ble_gap_conn_cancel");
  if (!conn_pending) return BLE_HS_EALREADY;
  conn_pending = false;
  return 0;
}

int
ble_gap_disc(uint8_t own_addr_type, int32_t duration_ms,
             const struct ble_gap_disc_params *disc_params,
             ble_gap_event_fn *cb, void *cb_arg)
{
  (void)own_addr_type;
  (void)duration_ms;
  (void)disc_params;
  (void)cb;
  (void)cb_arg;
  CALL_LOG("ble_gap_disc");
  disc_active = true;
  return 0;
}

int
ble_gap_disc_cancel(void)
{
  CALL_LOG("ble_gap_disc_cancel");
  bool was = disc_active;
  disc_active = false;
  return was ? 0 : BLE_HS_EALREADY;
}

int
ble_gap_disc_active(void)
{
  return disc_active;
}

struct rig_connect_arg {
  ble_gap_event_fn *cb;
  void *cb_arg;
};

static void
rig_peer_task(void *arg)
{
  struct rig_connect_arg a = *(struct rig_connect_arg *)arg;
  free(arg);
  vTaskDelay(pdMS_TO_TICKS(RIG_CONNECT_DELAY_MS));
  if (conn_pending) {
    conn_pending = false;
    struct ble_gap_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = BLE_GAP_EVENT_CONNECT;
    ev.connect.status = 0;
    ev.connect.conn_handle = RIG_LINK_HANDLE;
    printf("[rig] host CONNECT handle=%u\n", (unsigned)RIG_LINK_HANDLE);
    a.cb(&ev, a.cb_arg);
  }
  vTaskDelete(NULL);
}

int
ble_gap_connect(uint8_t own_addr_type, const ble_addr_t *peer_addr,
                int32_t duration_ms,
                const struct ble_gap_conn_params *params,
                ble_gap_event_fn *cb, void *cb_arg)
{
  (void)own_addr_type;
  (void)duration_ms;
  (void)params;
  CALL_LOG("ble_gap_connect");
  if (conn_pending) return BLE_HS_EALREADY;
  conn_pending = true;
  if (peer_addr != NULL && peer_addr->val[5] == RIG_ANSWERING_PEER) {
    struct rig_connect_arg *a = malloc(sizeof(*a));
    a->cb = cb;
    a->cb_arg = cb_arg;
    xTaskCreate(rig_peer_task, "evq_peer", 6144, a, 5, NULL);
  }
  return 0;
}

int
ble_gap_conn_find(uint16_t handle, struct ble_gap_conn_desc *out_desc)
{
  (void)handle;
  (void)out_desc;
  return BLE_HS_ENOTCONN;
}

int
ble_hs_id_copy_addr(uint8_t id_addr_type, uint8_t *out_id_addr, int *out_is_nrpa)
{
  (void)id_addr_type;
  if (out_id_addr != NULL) memset(out_id_addr, 0, 6);
  if (out_is_nrpa != NULL) *out_is_nrpa = 0;
  return 0;
}

int
ble_hs_util_ensure_addr(int prefer_random)
{
  (void)prefer_random;
  return 0;
}

int
ble_hs_id_infer_auto(int privacy, uint8_t *out_addr_type)
{
  (void)privacy;
  if (out_addr_type != NULL) *out_addr_type = 0;
  return 0;
}
