// Float と10進の変換 (mrb_fpconv_pkg) を tools/fpga/fpconv.rb の答えと突き合わせる。
// ベクタは fpga/tb/mrb_fpconv_vectors.txt (rake fpga:fpconv:vectors が作る。書式は tools/fpga/fpconv_vectors.rb)。
// plusargs: +vec=<file> で別のベクタ
`timescale 1ns / 1ps
/* verilator lint_off UNUSEDSIGNAL */
module mrb_fpconv_tb;
  import mrb_fpconv_pkg::*;

  initial begin
    int fd, kind, prec, e10, wl, bad, n;
    logic [63:0] bits, got_bits;
    logic [7:0] conv;
    big_t d;
    logic [8*FBUF-1:0] wb;
    str_t got, want;
    string path;
    if (!$value$plusargs("vec=%s", path)) path = "fpga/tb/mrb_fpconv_vectors.txt";
    fd = $fopen(path, "r");
    if (fd == 0) $fatal(1, "cannot open %s", path);
    bad = 0;
    n = 0;
    while ($fscanf(fd, "%d %h %h %d %d %h %d %h\n", kind, bits, conv, prec, e10, d, wl, wb) == 8) begin
      n++;
      want = {wb, 16'(wl)};
      if (kind == 0) begin
        got = f_to_s(bits);
        if (got != want) begin bad++; $display("FAIL to_s %h", bits); end
      end else if (kind == 1) begin
        got = f_fmt(bits, conv, prec);
        if (got != want) begin bad++; $display("FAIL format %%.%0d%c %h", prec, conv, bits); end
      end else begin
        got_bits = f_strtod(d, e10, 1'b0);
        if (got_bits != bits) begin bad++; $display("FAIL strtod %h e%0d", d, e10); end
      end
    end
    $fclose(fd);
    $display("%0d vectors, %0d bad", n, bad);
    if (n < 1000 || bad != 0) $fatal(1, "mrb_fpconv_tb failed");
    $display("PASS mrb_fpconv_tb");
    $finish;
  end
endmodule
