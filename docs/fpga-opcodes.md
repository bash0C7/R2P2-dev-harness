# FPGA コアの対応命令と、コーパスでの出現回数

`rake fpga:corpus` が `fpga/corpus/*.rb` の `mrbc -v` から生成する。手で直さない。
対応 = CPU コア (`fpga/rtl/mrb_core.sv`) と参照インタプリタ (`tools/fpga/ref_vm.rb`) が実行する命令
(`tools/fpga/isa.rb` の `SUPPORTED`)。意味と決定事項は [spec.md](spec.md) §10。

| op | 番号 | 形式 | 対応 | arith | blink | blink_loop | blink_method | blocks | button | counter | math | methods | pwm |
|---|---:|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| NOP | 0 | Z | yes | 1 | 2 |  | 2 |  | 1 | 1 |  |  | 2 |
| MOVE | 1 | BB | yes | 16 | 1 |  | 3 | 11 |  | 5 |  | 8 | 4 |
| LOADI8 | 3 | BB | yes | 5 |  |  |  | 2 |  | 1 | 6 | 3 | 2 |
| LOADINEG | 4 | BB | yes | 3 |  |  |  |  |  |  | 7 | 1 |  |
| LOADI__1 | 5 | B | yes | 1 |  |  |  |  |  |  | 1 | 1 |  |
| LOADI_0 | 6 | B | yes |  | 3 | 1 | 2 | 5 | 1 | 2 | 1 | 4 | 4 |
| LOADI_1 | 7 | B | yes | 1 | 1 | 1 | 1 | 2 | 2 | 1 | 1 | 3 | 1 |
| LOADI_2 | 8 | B | yes | 1 |  |  |  | 3 |  |  | 3 | 2 |  |
| LOADI_3 | 9 | B | yes | 1 |  |  |  | 5 |  |  | 5 |  |  |
| LOADI_4 | 10 | B | yes | 1 |  |  |  | 2 |  |  | 2 |  |  |
| LOADI_5 | 11 | B | yes | 1 |  |  |  | 1 |  |  | 2 |  |  |
| LOADI_6 | 12 | B | yes | 1 |  |  |  |  |  |  | 2 |  |  |
| LOADI_7 | 13 | B | yes | 1 |  |  |  | 1 |  |  | 5 | 1 |  |
| LOADI16 | 14 | BS | yes | 3 | 1 | 1 | 1 |  |  |  |  |  |  |
| LOADI32 | 15 | BSS | yes | 1 |  |  |  |  |  |  |  |  |  |
| LOADNIL | 17 | B | yes | 1 |  |  |  | 2 |  |  | 3 |  |  |
| LOADTRUE | 19 | B | yes | 1 |  |  |  |  |  | 1 |  |  |  |
| LOADFALSE | 20 | B | yes |  |  |  |  |  |  | 2 |  |  |  |
| GETGV | 21 | BB | yes |  | 1 |  | 1 |  | 1 |  |  |  |  |
| SETGV | 22 | BB | yes | 14 | 2 | 1 | 2 | 9 | 2 | 2 | 23 | 8 | 2 |
| GETCONST | 29 | BB | yes |  |  |  |  |  |  |  | 4 |  |  |
| SETCONST | 30 | BB | yes |  |  |  |  |  |  |  | 2 |  |  |
| GETUPVAR | 33 | BBB | yes |  |  | 1 |  | 7 |  |  |  |  |  |
| SETUPVAR | 34 | BBB | yes |  |  | 1 |  | 5 |  |  |  |  |  |
| JMP | 38 | S | yes | 7 | 2 |  | 2 | 2 | 2 | 3 |  | 1 | 3 |
| JMPIF | 39 | BS | yes | 1 |  |  |  |  |  |  |  |  |  |
| JMPNOT | 40 | BS | yes | 6 | 1 |  | 1 | 3 | 1 | 3 |  | 3 | 3 |
| JMPNIL | 41 | BS | yes |  |  |  |  |  |  |  |  |  |  |
| SSEND | 47 | BBB | yes |  |  |  | 2 | 2 |  |  |  | 9 |  |
| SSEND0 | 48 | BB | yes |  |  |  |  |  |  |  |  | 3 |  |
| SSENDB | 49 | BBB | **no** |  |  | 1 |  | 1 |  |  |  |  |  |
| SEND | 50 | BBB | yes |  |  |  |  |  |  |  | 11 |  |  |
| SEND0 | 51 | BB | yes |  |  |  |  | 2 |  |  | 7 |  |  |
| SENDB | 52 | BBB | **no** |  |  | 1 |  | 9 |  |  |  |  |  |
| ENTER | 57 | W | yes |  |  | 2 | 2 | 12 |  |  |  | 5 |  |
| RETURN | 61 | B | yes | 1 |  | 2 | 1 | 12 |  | 1 | 1 | 7 |  |
| RETNIL | 64 | Z | yes |  | 1 | 1 | 2 | 2 | 1 |  |  | 1 | 1 |
| BREAK | 67 | B | yes |  |  |  |  | 1 |  |  |  |  |  |
| ADD | 69 | B | yes | 1 |  |  |  | 4 |  |  | 1 | 3 |  |
| ADDI | 70 | BB | yes | 1 |  |  |  | 2 |  |  |  |  |  |
| SUB | 71 | B | yes | 1 | 1 | 1 | 1 |  |  |  |  |  |  |
| SUBI | 72 | BB | yes | 1 |  |  |  |  |  |  |  | 2 |  |
| ADDILV | 73 | BBB | yes |  | 2 |  | 1 |  |  | 1 |  |  | 2 |
| SUBILV | 74 | BBB | yes | 2 |  |  |  |  |  |  |  |  |  |
| MUL | 75 | B | yes |  |  |  |  | 4 |  |  | 2 |  |  |
| DIV | 76 | B | yes |  |  |  |  |  |  |  | 3 |  |  |
| EQ | 77 | B | yes | 1 |  |  |  |  | 1 |  |  | 1 |  |
| LT | 78 | B | yes | 1 | 1 |  | 1 |  |  | 1 |  | 2 | 2 |
| LE | 79 | B | yes | 1 |  |  |  |  |  |  |  |  |  |
| GT | 80 | B | yes | 1 |  |  |  | 1 |  |  |  |  | 1 |
| GE | 81 | B | yes | 1 |  |  |  |  |  |  |  |  |  |
| BLOCK | 98 | BB | **no** |  |  | 2 |  | 10 |  |  |  |  |  |
| TDEF | 107 | BBB | yes |  |  |  | 2 | 2 |  |  |  | 5 |  |
| STOP | 118 | Z | yes | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
