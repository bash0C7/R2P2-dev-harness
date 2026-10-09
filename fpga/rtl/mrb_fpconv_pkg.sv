// Float と10進の変換 (多倍長の整数だけで正確に)。mrb_core.sv の Float#to_s / format / String#__strtod が使う。
// 同じアルゴリズムの Ruby は tools/fpga/fpconv.rb、突き合わせは fpga/tb/mrb_fpconv_tb.sv (rake fpga:fpconv:vectors)。
// ループの回数が値で決まるのでシミュレーション用 (合成するならファームウェアか順序回路に置き換える)
`timescale 1ns / 1ps
// 関数は引数の一部の bit だけを読むものが多い (長さだけ、指数だけ、…)
/* verilator lint_off UNUSEDSIGNAL */
package mrb_fpconv_pkg;
  localparam int FW   = 1664; // 多倍長の幅 (10^400 と 2^1100 の積が入る)
  localparam int FBUF = 400;  // 作る文字列の最大バイト数
  typedef logic [FW-1:0] big_t;
  // 文字列 = {バイト (0 番目が下位) × FBUF, 長さ 16bit}。Icarus は構造体の部分への代入を受け付けないので素のベクタで
  typedef logic [8*FBUF+15:0] str_t;

  function automatic str_t fs_put(input str_t s, input logic [7:0] ch);
    str_t t;
    int n;
    t = s;
    n = int'(s[15:0]);
    if (n < FBUF) begin
      t[16 + 8*n +: 8] = ch;
      t[15:0] = 16'(n + 1);
    end
    return t;
  endfunction

  function automatic int fs_len(input str_t s);
    return int'(s[15:0]);
  endfunction

  function automatic logic [7:0] fs_at(input str_t s, input int i);
    return s[16 + 8*i +: 8];
  endfunction

  function automatic big_t pow10(input int p);
    big_t r;
    r = 1;
    for (int k = 0; k < p; k++) r = r * 10;
    return r;
  endfunction

  function automatic int bitlen(input big_t x);
    int n;
    n = 0;
    for (int i = 0; i < FW; i++) if (x[i]) n = i + 1;
    return n;
  endfunction

  // 多倍長の割り算 n / d (d > 0) を筆算で (Icarus 12 の / と % は値によって返らないので使わない)
  function automatic big_t bdiv(input big_t n, input big_t d);
    big_t q, r;
    q = 0;
    r = 0;
    for (int i = bitlen(n) - 1; i >= 0; i--) begin
      r = {r[FW-2:0], n[i]};
      if (r >= d) begin r = r - d; q[i] = 1'b1; end
    end
    return q;
  endfunction

  // 正の num / den を整数に丸める (0.5 は偶数へ)
  function automatic big_t round_even(input big_t num, input big_t den);
    big_t q, r;
    q = bdiv(num, den);
    r = num - q * den;
    if ((r << 1) > den || ((r << 1) == den && q[0])) q = q + 1;
    return q;
  endfunction

  // 正の有限の double の {仮数, 指数} (値 = f * 2^e)
  function automatic logic [52:0] f_mant(input logic [63:0] b);
    return {b[62:52] != 11'd0, b[51:0]};
  endfunction
  function automatic int f_exp(input logic [63:0] b);
    return b[62:52] == 11'd0 ? -1074 : int'(b[62:52]) - 1075;
  endfunction

  // 10 進の整数 q を文字列の後ろに (桁が width より少なければ前を 0 で埋める)
  function automatic str_t fs_dec(input str_t s, input big_t q, input int width);
    logic [8*FBUF-1:0] d;
    int n;
    big_t x, x10;
    str_t t;
    x = q;
    n = 0;
    while (x != 0 || n == 0 || n < width) begin
      x10 = bdiv(x, 10);
      d[8*n +: 8] = 8'd48 + 8'(x - x10 * 10);
      x = x10;
      n++;
    end
    t = s;
    for (int k = n - 1; k >= 0; k--) t = fs_put(t, d[8*k +: 8]);
    return t;
  endfunction

  // 最短で元に戻る10進の桁 (Burger & Dybvig。境界は仮数が偶数なら含み、最後の桁の真ん中は偶数へ)。
  // 桁は digs[0..n-1] (上から)、decpt は小数点の位置
  // 結果は {decpt 16bit, n 16bit, digs 20 バイト} (Icarus は関数からタスクを呼べないので関数に)
  function automatic logic [8*20+31:0] f_shortest(input logic [63:0] bits);
    logic [8*20-1:0] digs;
    int n, decpt;
    big_t r, s, mp, mm, q;
    logic [52:0] f;
    int e, k, d;
    logic even, tc1, tc2, done;
    f = f_mant(bits);
    e = f_exp(bits);
    even = !f[0];
    if (e >= 0) begin
      if (f != 53'h10_0000_0000_0000) begin r = big_t'(f) << (e + 1); s = 2; mp = big_t'(1) << e; mm = mp; end
      else begin r = big_t'(f) << (e + 2); s = 4; mp = big_t'(1) << (e + 1); mm = big_t'(1) << e; end
    end else if (e == -1074 || f != 53'h10_0000_0000_0000) begin
      r = big_t'(f) << 1; s = big_t'(1) << (1 - e); mp = 1; mm = 1;
    end else begin
      r = big_t'(f) << 2; s = big_t'(1) << (2 - e); mp = 2; mm = 1;
    end
    k = 0;
    while (even ? r + mp >= s : r + mp > s) begin s = s * 10; k++; end
    while (even ? (r + mp) * 10 < s : (r + mp) * 10 <= s) begin r = r * 10; mp = mp * 10; mm = mm * 10; k--; end
    n = 0;
    done = 1'b0;
    while (!done && n < 20) begin
      r = r * 10; mp = mp * 10; mm = mm * 10;
      q = bdiv(r, s);
      d = int'(q);
      r = r - q * s;
      tc1 = even ? r <= mm : r < mm;
      tc2 = even ? r + mp >= s : r + mp > s;
      if (!tc1 && !tc2) digs[8*n +: 8] = 8'(48 + d);
      else begin
        if (tc1 && !tc2) digs[8*n +: 8] = 8'(48 + d);
        else if (!tc1 && tc2) digs[8*n +: 8] = 8'(49 + d);
        else if ((r << 1) < s || ((r << 1) == s && d % 2 == 0)) digs[8*n +: 8] = 8'(48 + d);
        else digs[8*n +: 8] = 8'(49 + d);
        done = 1'b1;
      end
      n++;
    end
    decpt = k;
    return {16'(decpt), 16'(n), digs};
  endfunction

  // Ruby の Float#to_s
  function automatic str_t f_to_s(input logic [63:0] xb);
    str_t s;
    logic [8*20-1:0] digs;
    logic [15:0] decpt16, n16;
    int n, decpt, e;
    s = '0;
    if (xb[62:52] == 11'h7FF && xb[51:0] != 52'd0) begin
      s = fs_put(s, "N"); s = fs_put(s, "a"); s = fs_put(s, "N");
      return s;
    end
    if (xb[63]) s = fs_put(s, "-");
    if (xb[62:52] == 11'h7FF) begin
      s = fs_put(s, "I"); s = fs_put(s, "n"); s = fs_put(s, "f"); s = fs_put(s, "i"); s = fs_put(s, "n");
      s = fs_put(s, "i"); s = fs_put(s, "t"); s = fs_put(s, "y");
      return s;
    end
    if (xb[62:0] == 63'd0) begin
      s = fs_put(s, "0"); s = fs_put(s, "."); s = fs_put(s, "0");
      return s;
    end
    {decpt16, n16, digs} = f_shortest({1'b0, xb[62:0]});
    decpt = int'($signed(decpt16));
    n = int'(n16);
    if (decpt > 0 && (decpt <= 15 || (decpt == 16 && n > decpt))) begin
      for (int k = 0; k < decpt; k++) s = fs_put(s, k < n ? digs[8*k +: 8] : "0");
      s = fs_put(s, ".");
      if (n <= decpt) s = fs_put(s, "0");
      else for (int k = decpt; k < n; k++) s = fs_put(s, digs[8*k +: 8]);
    end else if (decpt <= 0 && decpt > -4) begin
      s = fs_put(s, "0"); s = fs_put(s, ".");
      for (int k = 0; k < -decpt; k++) s = fs_put(s, "0");
      for (int k = 0; k < n; k++) s = fs_put(s, digs[8*k +: 8]);
    end else begin
      e = decpt - 1;
      s = fs_put(s, digs[7:0]); s = fs_put(s, ".");
      if (n > 1) for (int k = 1; k < n; k++) s = fs_put(s, digs[8*k +: 8]);
      else s = fs_put(s, "0");
      s = fs_put(s, "e");
      s = fs_put(s, e < 0 ? "-" : "+");
      s = fs_dec(s, {{(FW-32){1'b0}}, e < 0 ? -e : e}, 2);
    end
    return s;
  endfunction

  // 正の有限の double を 10^p 倍して偶数丸め
  function automatic big_t f_scaled(input logic [63:0] bits, input int p);
    big_t num, den;
    int e;
    num = big_t'(f_mant(bits));
    den = 1;
    e = f_exp(bits);
    if (e >= 0) num = num << e; else den = den << (-e);
    if (p >= 0) num = num * pow10(p); else den = den * pow10(-p);
    return round_even(num, den);
  endfunction

  // 10^(k-1) <= v < 10^k の k (v > 0)
  function automatic int f_decexp(input logic [63:0] bits);
    big_t num, den;
    int e, k;
    num = big_t'(f_mant(bits));
    den = 1;
    e = f_exp(bits);
    if (e >= 0) num = num << e; else den = den << (-e);
    k = 0;
    while (num >= den) begin den = den * 10; k++; end
    while (num * 10 < den) begin num = num * 10; k--; end
    return k;
  endfunction

  // %.<prec>f / e / E / g / G (C の printf と同じく正確に丸める。PicoRuby と同じ)
  function automatic str_t f_fmt(input logic [63:0] xb, input logic [7:0] conv, input int prec);
    str_t s, m;
    logic [63:0] a;
    big_t q, lim;
    int k, x, p, fprec, last;
    logic use_e, upper;
    s = '0;
    a = {1'b0, xb[62:0]};
    if (xb[63]) s = fs_put(s, "-");
    upper = conv == "E" || conv == "G";
    p = prec;
    use_e = conv == "e" || conv == "E";
    fprec = prec;
    if (conv == "g" || conv == "G") begin
      p = prec == 0 ? 1 : prec;
      // %e で p-1 桁にした時の指数 x
      if (a == 64'd0) x = 0;
      else begin
        k = f_decexp(a);
        q = f_scaled(a, p - k);
        if (q >= pow10(p)) k++;
        x = k - 1;
      end
      use_e = x < -4 || x >= p;
      fprec = use_e ? p - 1 : p - 1 - x;
    end
    m = '0;
    if (use_e) begin
      if (a == 64'd0) begin q = 0; x = 0; end
      else begin
        k = f_decexp(a);
        q = f_scaled(a, fprec + 1 - k);
        lim = pow10(fprec + 1);
        if (q >= lim) begin k++; q = f_scaled(a, fprec + 1 - k); end
        x = k - 1;
      end
      m = fs_dec(m, q, fprec + 1);
    end else begin
      q = a == 64'd0 ? big_t'(0) : f_scaled(a, fprec);
      m = fs_dec(m, q, fprec + 1);
    end
    // m は小数点の無い桁 (use_e なら fprec + 1 桁、そうでなければ整数部 + fprec 桁)
    last = fs_len(m);
    if (conv == "g" || conv == "G") begin
      // 小数部の末尾の 0 と、残らなければ小数点を消す
      while (last > (use_e ? 1 : fs_len(m) - fprec) && fs_at(m, last - 1) == "0") last--;
    end
    if (use_e) begin
      s = fs_put(s, fs_at(m, 0));
      if (last > 1) begin
        s = fs_put(s, ".");
        for (int i = 1; i < last; i++) s = fs_put(s, fs_at(m, i));
      end
      s = fs_put(s, upper ? "E" : "e");
      s = fs_put(s, x < 0 ? "-" : "+");
      s = fs_dec(s, {{(FW-32){1'b0}}, x < 0 ? -x : x}, 2);
    end else begin
      for (int i = 0; i < fs_len(m) - fprec; i++) s = fs_put(s, fs_at(m, i));
      if (last > fs_len(m) - fprec) begin
        s = fs_put(s, ".");
        for (int i = fs_len(m) - fprec; i < last; i++) s = fs_put(s, fs_at(m, i));
      end
    end
    return s;
  endfunction

  // 10 進の d * 10^e10 を一番近い double に (0.5 は偶数へ)。neg は符号
  function automatic logic [63:0] f_strtod(input big_t d, input int e10, input logic neg);
    big_t num, den, q;
    int b, nd;
    logic [63:0] sign;
    sign = {neg, 63'd0};
    if (d == 0) return sign;
    // 桁数 nd: 値は 10^(nd+e10) より小さく 10^(nd+e10-1) 以上。最小の非正規化数の半分より小さければ 0、最大より大きければ無限
    nd = 0;
    num = 1;
    while (num <= d) begin num = num * 10; nd++; end
    if (nd + e10 < -324) return sign;
    if (nd + e10 > 310) return sign | 64'h7FF0_0000_0000_0000;
    num = d;
    den = 1;
    if (e10 >= 0) num = num * pow10(e10); else den = pow10(-e10);
    b = bitlen(num) - bitlen(den) - 53;
    while ((b < 0 ? num << (-b) : num) >= ((b > 0 ? den << b : den) << 53)) b++;
    while ((b < 0 ? num << (-b) : num) < ((b > 0 ? den << b : den) << 52)) b--;
    if (b < -1074) b = -1074;
    q = round_even(b < 0 ? num << (-b) : num, b > 0 ? den << b : den);
    if (q == (big_t'(1) << 53)) begin q = q >> 1; b++; end
    if (b + 52 > 1023) return sign | 64'h7FF0_0000_0000_0000;
    if (q < (big_t'(1) << 52)) return sign | 64'(q);
    return sign | {1'b0, 11'(b + 1075), q[51:0]};
  endfunction

  // String#__strtod の受ける形 (-?\d+(\.\d+)?([eE][-+]?\d+)?、プレリュードが整えたもの) を {読めたか, 符号, 10 の指数, 桁} に。
  // txt の k 番目のバイトは [8k +: 8]、n バイト (64 まで)。値 = 桁 * 10^指数。指数の数字は 9999 で頭打ち
  function automatic logic [FW+33:0] f_parse(input logic [8*64-1:0] txt, input int n);
    big_t d;
    int k, e10, ex, nf;
    logic neg, eneg, ok;
    logic [7:0] c;
    d = 0; e10 = 0; ex = 0; nf = 0; neg = 1'b0; eneg = 1'b0; ok = 1'b1;
    k = 0;
    if (k < n && txt[8*k +: 8] == "-") begin neg = 1'b1; k++; end
    if (!(k < n && txt[8*k +: 8] >= "0" && txt[8*k +: 8] <= "9")) ok = 1'b0;
    while (ok && k < n && txt[8*k +: 8] >= "0" && txt[8*k +: 8] <= "9") begin
      d = d * 10 + {{(FW-4){1'b0}}, txt[8*k +: 4]}; k++;
    end
    if (ok && k < n && txt[8*k +: 8] == ".") begin
      k++;
      if (!(k < n && txt[8*k +: 8] >= "0" && txt[8*k +: 8] <= "9")) ok = 1'b0;
      while (ok && k < n && txt[8*k +: 8] >= "0" && txt[8*k +: 8] <= "9") begin
        d = d * 10 + {{(FW-4){1'b0}}, txt[8*k +: 4]}; nf++; k++;
      end
    end
    if (ok && k < n && (txt[8*k +: 8] == "e" || txt[8*k +: 8] == "E")) begin
      k++;
      if (k < n && (txt[8*k +: 8] == "-" || txt[8*k +: 8] == "+")) begin eneg = txt[8*k +: 8] == "-"; k++; end
      if (!(k < n && txt[8*k +: 8] >= "0" && txt[8*k +: 8] <= "9")) ok = 1'b0;
      while (ok && k < n && txt[8*k +: 8] >= "0" && txt[8*k +: 8] <= "9") begin
        c = txt[8*k +: 8];
        ex = ex * 10 + int'({28'd0, c[3:0]});
        if (ex > 9999) ex = 9999;
        k++;
      end
    end
    if (k != n) ok = 1'b0;
    e10 = (eneg ? -ex : ex) - nf;
    return {ok, neg, 32'(e10), d};
  endfunction
endpackage
/* verilator lint_on UNUSEDSIGNAL */
