# rake fpga:* の中で、互いに独立な仕事 (1 本ごとの compile・変換・参照・シミュレーション) を CPU の数だけ並べて回す。
# 返す順は items の順 (出力を1本ずつ回した時と同じ並びにする)。仕事の例外は親で同じ message の例外にする (黙って落とさない)。
# 本数は FPGA_JOBS、無ければ CPU の数。1 なら fork も thread も使わず、その場で順に回す (調べる時に使う)
require "etc"

module FpgaParallel
  class Error < StandardError; end

  module_function

  def jobs
    n = ENV["FPGA_JOBS"].to_s
    n.empty? ? Etc.nprocessors : Integer(n).clamp(1, 256)
  end

  # CPU を使う仕事 (CRuby の参照インタプリタなど。GVL があるので thread では並ばない)。fork した子で回し、結果は Marshal で返す
  def map(items, jobs: self.jobs, &work)
    items = items.to_a
    return items.map(&work) if jobs <= 1 || items.size <= 1
    results = Array.new(items.size)
    queue = items.each_index.to_a
    running = {} # pid => [index, reader]
    until queue.empty? && running.empty?
      while running.size < jobs && !queue.empty?
        i = queue.shift
        r, w = IO.pipe
        pid = fork do
          r.close
          out = begin
            [:ok, work.call(items[i])]
          rescue Exception => e # rubocop:disable Lint/RescueException -- 子の中の何が起きても親に届ける
            [:error, "#{e.class}: #{e.message}"]
          end
          w.binmode.write(Marshal.dump(out))
          w.close
          exit!(0)
        end
        w.close
        running[pid] = [i, r]
      end
      # 終わった子から読む。読まないと pipe が詰まって子が終われないので、読んでから wait する
      ready, = IO.select(running.values.map(&:last))
      ready.each do |r|
        pid, (i, _) = running.find { |_, (_, rr)| rr == r }
        data = r.binmode.read
        r.close
        Process.wait(pid)
        running.delete(pid)
        raise Error, "item #{i}: worker exited with #{$?.exitstatus} and no result" if data.empty?
        kind, value = Marshal.load(data)
        raise Error, "item #{i}: #{value}" if kind == :error
        results[i] = value
      end
    end
    results
  ensure
    running&.each_key { |pid| Process.kill(:TERM, pid) rescue nil } # 例外で抜けたら残った子を止める
    running&.each_key { |pid| Process.wait(pid) rescue nil }
  end

  # 外の process (mrbc、picoruby の変換器、シミュレーター) を待つだけの仕事。thread で回す
  def threads(items, jobs: self.jobs, &work)
    items = items.to_a
    return items.map(&work) if jobs <= 1 || items.size <= 1
    results = Array.new(items.size)
    errors = []
    queue = Queue.new
    items.each_index { |i| queue << i }
    queue.close
    Array.new([jobs, items.size].min) do
      Thread.new do
        while (i = queue.pop)
          begin
            results[i] = work.call(items[i])
          rescue StandardError => e
            errors << [i, e]
          end
        end
      end
    end.each(&:join)
    unless errors.empty?
      i, e = errors.min_by(&:first)
      raise Error, "item #{i}: #{e.class}: #{e.message}"
    end
    results
  end
end
