# 棚卸し (計画 S2-1) の reflection: host の PicoRuby で走らせ、定数から辿れる全てのクラスとモジュールについて、
# 自分で持つメソッドと定数を 1 行ずつ出す。行は「種類<TAB>持ち主<TAB>名前」
#   pub / priv / prot / sing (特異、public) / spriv (特異、private): メソッド、const: 定数 (クラスとモジュールも)
#   一番外の self (main) の特異メソッドは、持ち主 main で出す
# mruby ソースコード (host の PicoRuby で走る)。順は道具 (tools/fpga/v2/inventory.rb) が並べ直す
self.singleton_methods(false).each { |m| puts "sing\tmain\t#{m}" }
self.singleton_class.private_instance_methods(false).each { |m| puts "spriv\tmain\t#{m}" }

seen = []
queue = [Object]
until queue.empty?
  mod = queue.shift
  next if seen.any? { |m| m.equal?(mod) }

  seen << mod
  name = mod.to_s # PicoRuby に Module#name は無い。無名は "#<" で始まる
  next if name.start_with?("#<")

  mod.instance_methods(false).each { |m| puts "pub\t#{name}\t#{m}" }
  mod.private_instance_methods(false).each { |m| puts "priv\t#{name}\t#{m}" }
  mod.protected_instance_methods(false).each { |m| puts "prot\t#{name}\t#{m}" }
  mod.singleton_methods(false).each { |m| puts "sing\t#{name}\t#{m}" }
  mod.singleton_class.private_instance_methods(false).each { |m| puts "spriv\t#{name}\t#{m}" }
  mod.constants(false).each do |c|
    puts "const\t#{name}\t#{c}"
    v = mod.const_get(c)
    queue << v if v.is_a?(Module)
  end
end
