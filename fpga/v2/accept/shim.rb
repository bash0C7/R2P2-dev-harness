# accept (計画 S1) の shim: mruby-test の driver.c が C で足す Kernel#t_print と Kernel#_str_match? を写したもの。
# host の PicoRuby と参照 v2 の両方で、mruby の test/assert.rb の前に読む (assert.rb はこれらを RUBY_ENGINE == "mruby" の時に定義しない)。
# バイトは getbyte の数で扱う (92 \、42 *、63 ?、91 [、93 ]、33 !、94 ^、45 -、123 {、125 }、44 ,)

# C: mrbgems/mruby-test/driver.c mrb_init_test_driver (Mrbtest の FLOAT_TOLERANCE。MRB_USE_FLOAT32 でない build の値。
# nofree_cstr? は RSTRING_CSTR の C の test なので写さない: 使う assert は範囲外 D31)
module Mrbtest
  FLOAT_TOLERANCE = 1e-10 if Object.const_defined?(:Float)
end

# C: mrbgems/mruby-test/driver.c t_print
def t_print(*args)
  i = 0
  while i < args.size
    print args[i].to_s # mrb_obj_as_string
    i += 1
  end
  nil
end

# C: mrbgems/mruby-test/driver.c m_str_match_p
def _str_match?(pat, str)
  __t_str_match_p(pat, str, 0)
end

# C: mrbgems/mruby-test/driver.c UNESCAPE
def __t_unescape(pat, p, pat_end)
  p != pat_end && pat.getbyte(p) == 92 ? p + 1 : p
end

# C: mrbgems/mruby-test/driver.c str_match_bracket (c は照らす文字のバイト。返すのは ] の次の位置か nil)
def __t_str_match_bracket(pat, p, pat_end, c)
  ok = false
  negated = false
  return nil if p == pat_end
  b = pat.getbyte(p)
  if b == 33 || b == 94
    negated = true
    p += 1
  end
  while pat.getbyte(p) != 93
    t1 = __t_unescape(pat, p, pat_end)
    return nil if t1 == pat_end
    p = t1 + 1
    return nil if p == pat_end
    if pat.getbyte(p) == 45 && pat.getbyte(p + 1) != 93
      t2 = __t_unescape(pat, p + 1, pat_end)
      return nil if t2 == pat_end
      p = t2 + 1
      ok = true if !ok && pat.getbyte(t1) <= c && c <= pat.getbyte(t2)
    elsif !ok && pat.getbyte(t1) == c
      ok = true
    end
  end
  ok == negated ? nil : p + 1
end

# C: mrbgems/mruby-test/driver.c str_match_no_brace_p
def __t_str_match_no_brace_p(pat, str)
  p = 0
  s = 0
  pat_end = pat.bytesize
  str_end = str.bytesize
  p_tmp = nil
  s_tmp = nil
  while true
    return s == str_end if p == pat_end
    failed = false
    b = pat.getbyte(p)
    if b == 42
      p += 1
      p += 1 while p != pat_end && pat.getbyte(p) == 42
      return true if __t_unescape(pat, p, pat_end) == pat_end
      return false if s == str_end
      p_tmp = p
      s_tmp = s
      next
    elsif b == 63
      return false if s == str_end
      p += 1
      s += 1
      next
    elsif b == 91
      return false if s == str_end
      t = __t_str_match_bracket(pat, p + 1, pat_end, str.getbyte(s))
      if t
        p = t
        s += 1
        next
      end
      failed = true
    end
    unless failed
      # ordinary
      p = __t_unescape(pat, p, pat_end)
      return p == pat_end if s == str_end
      if p == pat_end
        failed = true
      else
        same = pat.getbyte(p) == str.getbyte(s)
        p += 1
        s += 1
        next if same
      end
    end
    # L_failed
    if p_tmp && s_tmp
      p = p_tmp
      s_tmp += 1
      s = s_tmp
      next
    end
    return false
  end
end

# C: mrbgems/mruby-test/driver.c str_match_p ({a,b} を展開して照らす。深さは STR_MATCH_MAX_BRACE_DEPTH 100)
def __t_str_match_p(pat, str, depth)
  return false if depth > 100
  p = 0
  pat_end = pat.bytesize
  lbrace = nil
  rbrace = nil
  nest = 0
  while p != pat_end
    b = pat.getbyte(p)
    if b == 123
      lbrace = p if nest == 0
      nest += 1
    elsif b == 125 && lbrace && (nest -= 1) == 0
      rbrace = p
      break
    elsif b == 92
      p += 1
      break if p == pat_end
    end
    p += 1
  end

  if lbrace && rbrace
    ret = false
    head = pat.byteslice(0, lbrace)
    tail = pat.byteslice(rbrace + 1, pat_end - rbrace - 1)
    p = lbrace
    while p < rbrace
      p += 1
      t = p
      nest = 0
      while p < rbrace && !(pat.getbyte(p) == 44 && nest == 0)
        b = pat.getbyte(p)
        if b == 123
          nest += 1
        elsif b == 125
          nest -= 1
        elsif b == 92
          p += 1
          break if p == rbrace
        end
        p += 1
      end
      ret = __t_str_match_p(head + pat.byteslice(t, p - t) + tail, str, depth + 1)
      break if ret
    end
    ret
  elsif !lbrace && !rbrace
    __t_str_match_no_brace_p(pat, str)
  else
    false
  end
end
