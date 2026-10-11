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
 *   terminate     ble_gap_terminate answers 0 for a link not yet terminating and
 *                 BLE_HS_EALREADY for one that is (BLE_HS_CONN_F_TERMINATING, nb ble_gap.c
 *                 in both trees); the flag clears when the link's DISCONNECT is raised or a
 *                 new CONNECT for the handle arrives. The DISCONNECT never comes, unless
 *                 rig_stub_late_disconnect armed it: then the DISCONNECT of the
 *                 terminated link (reason BLE_HS_HCI_ERR(0x16)) is raised from a task of
 *                 its own that many milliseconds later. The arming is consumed by the first
 *                 terminate that follows.
 *   peers         address byte 0xAA never answers; 0xBB answers with a CONNECT after 30 ms;
 *                 0xCC answers the same way but ble_gap_conn_cancel then fails with
 *                 BLE_HS_HCI_ERR(0x0C), as when the controller completed the connection
 *                 first, and the terminate of that link is armed to be answered 300 ms late.
 *   callouts      ble_npl_callout_* go through npl_funcs, which the host never initialises under
 *                 QEMU; rig_stub_install_npl() gives it a table with the callout functions only,
 *                 built on esp_timer: the callback runs from the esp_timer task, standing in for
 *                 the host task. ble_npl_time_ms_to_ticks32 is the identity, as in the esp_timer
 *                 mode of the porting layer.
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
#include "nimble/nimble_port.h"
#include "esp_timer.h"

#include "ble_common.h"

#define RIG_LINK_HANDLE 0x0033
#define RIG_CONNECT_DELAY_MS 30
#define RIG_ANSWERING_PEER 0xBB
#define RIG_RACING_PEER 0xCC
#define RIG_RACING_LATE_DISCONNECT_MS 300

extern volatile uint8_t picoruby_ble_power __attribute__((weak));
extern volatile uint8_t ble_power __attribute__((weak));

#ifdef PICORUBY_QEMU_EVQ_RESYNC
extern int rig_gap_adv_start(void);
#endif

static volatile bool adv_active = false;
static volatile bool disc_active = false;
static volatile bool conn_pending = false;
static volatile int late_disconnect_ms = 0;
static volatile bool conn_race = false;
static volatile int terminating_handle = -1;

void
rig_stub_late_disconnect(int ms)
{
  late_disconnect_ms = ms;
}

struct rig_late_arg {
  uint16_t handle;
  int ms;
};

static void
rig_late_disconnect_task(void *arg)
{
  struct rig_late_arg a = *(struct rig_late_arg *)arg;
  free(arg);
  vTaskDelay(pdMS_TO_TICKS(a.ms));
  struct ble_gap_event ev;
  memset(&ev, 0, sizeof(ev));
  ev.type = BLE_GAP_EVENT_DISCONNECT;
  ev.disconnect.reason = BLE_HS_HCI_ERR(0x16);
  ev.disconnect.conn.conn_handle = a.handle;
  printf("[rig] host DISCONNECT handle=%u\n", (unsigned)a.handle);
  if (terminating_handle == (int)a.handle) terminating_handle = -1;
  picoruby_ble_gap_event(&ev, NULL);
  vTaskDelete(NULL);
}

static unsigned
power_now(void)
{
  if (&picoruby_ble_power != NULL) return picoruby_ble_power;
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
  const int rc = (terminating_handle == (int)conn_handle) ? BLE_HS_EALREADY : 0;
  printf("[rig] nimble ble_gap_terminate handle=%u reason=0x%02x -> %d power=%u\n",
         (unsigned)conn_handle, (unsigned)hci_reason, rc, power_now());
  if (rc != 0) return rc;
  terminating_handle = conn_handle;
  const int ms = late_disconnect_ms;
  late_disconnect_ms = 0;
  if (ms > 0) {
    struct rig_late_arg *a = malloc(sizeof(*a));
    a->handle = conn_handle;
    a->ms = ms;
    xTaskCreate(rig_late_disconnect_task, "evq_late", 6144, a, 5, NULL);
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
  if (conn_race) return BLE_HS_HCI_ERR(0x0C);
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
    terminating_handle = -1;
    if (conn_race) {
      conn_race = false;
      late_disconnect_ms = RIG_RACING_LATE_DISCONNECT_MS;
    }
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
  conn_race = peer_addr != NULL && peer_addr->val[5] == RIG_RACING_PEER;
  if (peer_addr != NULL && (peer_addr->val[5] == RIG_ANSWERING_PEER || conn_race)) {
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

/* The callout functions the port uses reach the porting layer through npl_funcs, a table the
 * host fills in nimble_port_init(), which the rig never runs. The rig's table has the callout
 * functions and the millisecond conversion only. */
struct rig_callout {
  esp_timer_handle_t timer;
  ble_npl_event_fn *fn;
  void *arg;
  struct ble_npl_event ev;
};

static void
rig_callout_fire(void *arg)
{
  struct rig_callout *rc = arg;
  printf("[rig] host callout fired power=%u\n", power_now());
  rc->ev.event = rc->arg;
  rc->fn(&rc->ev);
}

static int
rig_npl_callout_init(struct ble_npl_callout *co, struct ble_npl_eventq *evq,
                     ble_npl_event_fn *ev_cb, void *ev_arg)
{
  (void)evq;
  struct rig_callout *rc = co->co;
  if (rc == NULL) {
    rc = calloc(1, sizeof(*rc));
    const esp_timer_create_args_t args = { .callback = rig_callout_fire, .arg = rc, .name = "evq_callout" };
    if (rc == NULL || esp_timer_create(&args, &rc->timer) != ESP_OK) return -1;
    co->co = rc;
  }
  rc->fn = ev_cb;
  rc->arg = ev_arg;
  printf("[rig] nimble callout_init power=%u\n", power_now());
  return 0;
}

static ble_npl_error_t
rig_npl_callout_reset(struct ble_npl_callout *co, ble_npl_time_t ticks)
{
  struct rig_callout *rc = co->co;
  printf("[rig] nimble callout_reset ms=%u power=%u\n", (unsigned)ticks, power_now());
  esp_timer_stop(rc->timer);
  return esp_timer_start_once(rc->timer, (uint64_t)ticks * 1000) == ESP_OK ? BLE_NPL_OK : BLE_NPL_ERROR;
}

static void
rig_npl_callout_stop(struct ble_npl_callout *co)
{
  struct rig_callout *rc = co->co;
  if (rc == NULL) return;
  printf("[rig] nimble callout_stop power=%u\n", power_now());
  esp_timer_stop(rc->timer);
}

static void
rig_npl_callout_deinit(struct ble_npl_callout *co)
{
  struct rig_callout *rc = co->co;
  if (rc == NULL) return;
  printf("[rig] nimble callout_deinit power=%u\n", power_now());
  esp_timer_stop(rc->timer);
  esp_timer_delete(rc->timer);
  free(rc);
  co->co = NULL;
}

static ble_npl_time_t
rig_npl_ms_to_ticks32(uint32_t ms)
{
  return ms;
}

static struct npl_funcs_t rig_npl = {
  .p_ble_npl_callout_init = rig_npl_callout_init,
  .p_ble_npl_callout_reset = rig_npl_callout_reset,
  .p_ble_npl_callout_stop = rig_npl_callout_stop,
  .p_ble_npl_callout_deinit = rig_npl_callout_deinit,
  .p_ble_npl_time_ms_to_ticks32 = rig_npl_ms_to_ticks32,
};

void
rig_stub_install_npl(void)
{
  if (npl_funcs == NULL) npl_funcs = &rig_npl;
}

struct ble_npl_eventq *
nimble_port_get_dflt_eventq(void)
{
  static struct ble_npl_eventq rig_eventq;
  return &rig_eventq;
}
