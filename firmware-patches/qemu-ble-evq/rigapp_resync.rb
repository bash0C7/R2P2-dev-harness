# Device program of the resync case (apply.sh copies it to storage/home/app.rb when EVQ_RESYNC=1).
# Starts a peripheral twice. The rig's host (rig_injector.c) syncs once per start and, in the
# first session, resets and syncs again after the first start has returned. Log tokens:
#   [rigapp] resync control     the control advertise follows the first BLE.new
#   [rigapp] resync second new  the second BLE.new follows, after the reset and re-sync
#   [rigapp] resync done
# The rig logs "[rig] ble_gap_adv_start rc=<rc> ..." for every advertise.
require 'ble'

ADV = "\x02\x01\x06"

def wait_ms(ms)
  t = Machine.board_millis
  while Machine.board_millis - t < ms
  end
end

first = BLE.new(:peripheral)
puts "[rigapp] resync control"
first.advertise(ADV)
wait_ms(1200)
puts "[rigapp] resync second new"
second = BLE.new(:peripheral)
second.advertise(ADV)
wait_ms(500)
puts "[rigapp] resync done"
