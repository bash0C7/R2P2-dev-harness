// 道具 (tools/fpga/rite_image.rb) が作る起動の像の番号。手で直さない (rake fpga:rite:hex で作り直す)
`timescale 1ns / 1ps
// 表として全部並べる (回路が使わない番号もある)
/* verilator lint_off UNUSEDPARAM */
package rite_image_pkg;
  localparam int SW = 8;  // sym の番号の幅
  localparam int CW = 5;  // クラスの番号の幅
  localparam int FW = 4;  // C の関数の番号の幅
  // presym (sym の番号。0 は名前の無い sym)
  localparam logic [SW-1:0] N_GPIO = SW'(1);  // GPIO
  localparam logic [SW-1:0] N_KERNEL = SW'(2);  // Kernel
  localparam logic [SW-1:0] N_OBJECT = SW'(3);  // Object
  localparam logic [SW-1:0] N_IN = SW'(4);  // IN
  localparam logic [SW-1:0] N_OUT = SW'(5);  // OUT
  localparam logic [SW-1:0] N_HIGH_Z = SW'(6);  // HIGH_Z
  localparam logic [SW-1:0] N_PULL_UP = SW'(7);  // PULL_UP
  localparam logic [SW-1:0] N_PULL_DOWN = SW'(8);  // PULL_DOWN
  localparam logic [SW-1:0] N_OPEN_DRAIN = SW'(9);  // OPEN_DRAIN
  localparam logic [SW-1:0] N_ALT = SW'(10);  // ALT
  localparam logic [SW-1:0] N_NEW = SW'(11);  // new
  localparam logic [SW-1:0] N_INITIALIZE = SW'(12);  // initialize
  localparam logic [SW-1:0] N_AT_PIN = SW'(13);  // @pin
  localparam logic [SW-1:0] N_UINIT = SW'(14);  // _init
  localparam logic [SW-1:0] N_SET_DIR_AT = SW'(15);  // set_dir_at
  localparam logic [SW-1:0] N_WRITE = SW'(16);  // write
  localparam logic [SW-1:0] N_SLEEP_MS = SW'(17);  // sleep_ms
  localparam logic [SW-1:0] N_MODULE_FUNCTION = SW'(18);  // module_function
  localparam logic [SW-1:0] N_ATTR_READER = SW'(19);  // attr_reader
  localparam logic [SW-1:0] N_AND = SW'(20);  // &
  localparam logic [SW-1:0] N_OR = SW'(21);  // |
  localparam logic [SW-1:0] N_RSHIFT = SW'(22);  // >>
  localparam logic [SW-1:0] N_EQQ = SW'(23);  // ===
  localparam logic [SW-1:0] N_NOT = SW'(24);  // !
  // クラス (0 は無い)
  localparam logic [CW-1:0] C_BASIC = CW'(1);
  localparam logic [CW-1:0] C_OBJECT = CW'(2);
  localparam logic [CW-1:0] C_MODULE = CW'(3);
  localparam logic [CW-1:0] C_CLASS = CW'(4);
  localparam logic [CW-1:0] C_KERNEL = CW'(5);
  localparam logic [CW-1:0] C_I_KERNEL = CW'(6);
  localparam logic [CW-1:0] C_INTEGER = CW'(7);
  localparam logic [CW-1:0] C_NIL = CW'(8);
  localparam logic [CW-1:0] C_TRUE = CW'(9);
  localparam logic [CW-1:0] C_FALSE = CW'(10);
  localparam logic [CW-1:0] C_SYMBOL = CW'(11);
  localparam logic [CW-1:0] C_PROC = CW'(12);
  localparam logic [CW-1:0] C_GPIO = CW'(13);
  localparam logic [CW-1:0] C_S_BASIC = CW'(14);
  localparam logic [CW-1:0] C_S_OBJECT = CW'(15);
  localparam logic [CW-1:0] C_S_KERNEL = CW'(16);
  localparam logic [CW-1:0] C_S_GPIO = CW'(17);
  // C の関数
  localparam logic [FW-1:0] F_NEW = FW'(0);  // class.c mrb_instance_new
  localparam logic [FW-1:0] F_DO_NOTHING = FW'(1);  // class.c mrb_do_nothing
  localparam logic [FW-1:0] F_UINIT = FW'(2);  // picoruby-gpio gpio.c mrb__init
  localparam logic [FW-1:0] F_SET_DIR_AT = FW'(3);  // picoruby-gpio gpio.c mrb_s_set_dir_at
  localparam logic [FW-1:0] F_WRITE = FW'(4);  // picoruby-gpio gpio.c mrb_write
  localparam logic [FW-1:0] F_SLEEP_MS = FW'(5);  // mruby-task task.c mrb_f_sleep_ms
  localparam logic [FW-1:0] F_MODFUNC = FW'(6);  // class.c mrb_mod_module_function
  localparam logic [FW-1:0] F_ATTR_READER = FW'(7);  // class.c mrb_mod_attr_reader
  localparam logic [FW-1:0] F_AND = FW'(8);  // numeric.c int_and
  localparam logic [FW-1:0] F_OR = FW'(9);  // numeric.c int_or
  localparam logic [FW-1:0] F_RSHIFT = FW'(10);  // numeric.c int_rshift
  localparam logic [FW-1:0] F_EQQ = FW'(11);  // kernel.c mrb_eqq_m
  localparam logic [FW-1:0] F_NOT = FW'(12);  // class.c mrb_bob_not
endpackage
/* verilator lint_on UNUSEDPARAM */
