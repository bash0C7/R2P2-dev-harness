# 棚卸しから出す 2 つの表 (計画 S2-4、rake fpga:v2:inventory が一緒に作る)
#   - fpga/v2/inventory/assert_needs.tsv: accept の土台 (shim、assert.rb、tally、report) が呼ぶメソッドの名前と、それを持つ板のクラス
#     (写し元つき)。計画 S4 で assert.rb を走らせるために写す集合
#   - fpga/v2/accept/gems.tsv: mruby の test/t の assert ごとに、中で呼ぶ名前のうち core (mruby-core) に無く gem にだけある名前の gem。
#     計画 S5 の完了は gem の無い assert で数える
# 名前はメソッドの呼び出しの名前 (Prism の CallNode) で、受け手のクラスは静的には分からないので、その名前を持つ全部の行を出す
require "prism"
require_relative "inventory"
require_relative "accept"

module FpgaV2
  module Needs
    ASSERT_NEEDS = File.join(Inventory::ROOT, "fpga", "v2", "inventory", "assert_needs.tsv")
    GEMS = File.join(Inventory::ROOT, "fpga", "v2", "accept", "gems.tsv")

    class Calls < Prism::Visitor
      attr_reader :names

      def initialize
        super()
        @names = []
      end

      def visit_call_node(node)
        @names << node.name.to_s
        super
      end
    end

    module_function

    def rows
      @rows ||= File.readlines(Inventory::OUT, chomp: true).reject { |l| l.start_with?("#") }.map { |l| l.split("\t", -1) }
    end

    def calls_in(node)
      v = Calls.new
      node.accept(v)
      v.names.uniq
    end

    def assert_needs
      files = Accept.files("array").values_at(0, 1, 2, 4) # shim、assert.rb、tally、report (test/t の file は除く)
      names = files.flat_map { |f| calls_in(Prism.parse_file(f).value) }.uniq.sort
      out = names.flat_map do |n|
        rs = rows.select { |r| r[2] == n && r[5] == "yes" && r[0] != "const" }
        rs.map { |r| [n, "#{r[0]} #{r[1]}", r[3]] }
      end
      "# accept の土台 (shim、assert.rb、tally、report) が呼ぶ名前と、それを持つ板の行 (計画 S4 の入力、rake fpga:v2:inventory が作る)\n" \
        "# name<TAB>kind owner<TAB>src\n" + out.map { |r| r.join("\t") }.join("\n") + "\n"
    end

    # 土台 (shim、assert.rb、tally、report) が def する名前 (assert_equal など。gem の同じ名前 (picotest) と取り違えない)
    def defined_names(node, acc = [])
      acc << node.name.to_s if node.is_a?(Prism::DefNode)
      node.compact_child_nodes.each { |c| defined_names(c, acc) }
      acc
    end

    # test/t の一番外の assert(名前) do ... end ごとに、gem にだけある名前の gem
    def assert_gems
      base = Accept.files("array").values_at(0, 1, 2, 4).flat_map { |f| defined_names(Prism.parse_file(f).value) }.uniq
      core_names = rows.select { |r| r[4].split.include?("mruby-core") }.map { |r| r[2] }.uniq + base
      gem_of = Hash.new { |h, k| h[k] = [] }
      rows.each { |r| r[4].split.each { |g| gem_of[r[2]] << g unless g == "mruby-core" || g == "-" } }
      out = []
      Accept.names.each do |file|
        tree = Prism.parse_file(File.join(Accept::TEST_DIR, "#{file}.rb")).value
        tree.statements.body.each do |st|
          next unless st.is_a?(Prism::CallNode) && st.name == :assert && st.block

          arg = st.arguments&.arguments&.first
          name = arg.respond_to?(:unescaped) ? arg.unescaped : "assert"
          gems = calls_in(st.block).reject { |n| core_names.include?(n) }.flat_map { |n| gem_of[n] }.uniq.sort
          out << [file, name, gems.empty? ? "-" : gems.join(" ")]
        end
      end
      "# test/t の assert ごとに、core に無く gem にだけある名前の gem (計画 S5 は - の assert で数える。rake fpga:v2:inventory が作る)\n" \
        "# file<TAB>assert<TAB>gems\n" + out.map { |r| r.join("\t") }.join("\n") + "\n"
    end
  end
end
