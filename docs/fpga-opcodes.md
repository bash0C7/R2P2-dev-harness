# FPGA コアの対応命令と、コーパスでの出現回数

`rake fpga:corpus` が `fpga/corpus/*.rb` の `mrbc -v` から生成する。手で直さない。
対応 = CPU コア (`fpga/rtl/mrb_core.sv`) と参照インタプリタ (`tools/fpga/ref_vm.rb`) が実行する命令
(`tools/fpga/isa.rb` の `SUPPORTED`)。意味と決定事項は [spec.md](spec.md) §10。

| op | 番号 | 形式 | 対応 | arith | blink | button | counter | pwm |
|---|---:|---|---|---:|---:|---:|---:|---:|
| NOP | 0 | Z | yes | 1 | 2 | 1 | 1 | 2 |
| MOVE | 1 | BB | yes | 16 | 1 |  | 5 | 4 |
| LOADI8 | 3 | BB | yes | 5 |  |  | 1 | 2 |
| LOADINEG | 4 | BB | yes | 3 |  |  |  |  |
| LOADI__1 | 5 | B | yes | 1 |  |  |  |  |
| LOADI_0 | 6 | B | yes |  | 3 | 1 | 2 | 4 |
| LOADI_1 | 7 | B | yes | 1 | 1 | 2 | 1 | 1 |
| LOADI_2 | 8 | B | yes | 1 |  |  |  |  |
| LOADI_3 | 9 | B | yes | 1 |  |  |  |  |
| LOADI_4 | 10 | B | yes | 1 |  |  |  |  |
| LOADI_5 | 11 | B | yes | 1 |  |  |  |  |
| LOADI_6 | 12 | B | yes | 1 |  |  |  |  |
| LOADI_7 | 13 | B | yes | 1 |  |  |  |  |
| LOADI16 | 14 | BS | yes | 3 | 1 |  |  |  |
| LOADI32 | 15 | BSS | yes | 1 |  |  |  |  |
| LOADNIL | 17 | B | yes | 1 |  |  |  |  |
| LOADTRUE | 19 | B | yes | 1 |  |  | 1 |  |
| LOADFALSE | 20 | B | yes |  |  |  | 2 |  |
| GETGV | 21 | BB | yes |  | 1 | 1 |  |  |
| SETGV | 22 | BB | yes | 14 | 2 | 2 | 2 | 2 |
| JMP | 38 | S | yes | 7 | 2 | 2 | 3 | 3 |
| JMPIF | 39 | BS | yes | 1 |  |  |  |  |
| JMPNOT | 40 | BS | yes | 6 | 1 | 1 | 3 | 3 |
| JMPNIL | 41 | BS | yes |  |  |  |  |  |
| RETURN | 61 | B | yes | 1 |  |  | 1 |  |
| RETNIL | 64 | Z | yes |  | 1 | 1 |  | 1 |
| ADD | 69 | B | yes | 1 |  |  |  |  |
| ADDI | 70 | BB | yes | 1 |  |  |  |  |
| SUB | 71 | B | yes | 1 | 1 |  |  |  |
| SUBI | 72 | BB | yes | 1 |  |  |  |  |
| ADDILV | 73 | BBB | yes |  | 2 |  | 1 | 2 |
| SUBILV | 74 | BBB | yes | 2 |  |  |  |  |
| EQ | 77 | B | yes | 1 |  | 1 |  |  |
| LT | 78 | B | yes | 1 | 1 |  | 1 | 2 |
| LE | 79 | B | yes | 1 |  |  |  |  |
| GT | 80 | B | yes | 1 |  |  |  | 1 |
| GE | 81 | B | yes | 1 |  |  |  |  |
| STOP | 118 | Z | yes | 1 | 1 | 1 | 1 | 1 |
