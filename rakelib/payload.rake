require_relative "../tools/common/mrbc"

# upload / run が板に置くものを決める。既定は mrbc で .mrb に compile して送る
# (実機で prism が .rb を compile すると heap を食い NoMemoryError になる。
# docs/spec.md §9)。HARNESS_SEND_RB=1 で .rb をそのまま送る。MRBC= で mrbc を差し替える。
def prepare_payload(src, remote, firmware_mrbc)
  Mrbc.prepare(src, remote: remote, mrbc: ENV["MRBC"] || firmware_mrbc,
                    out_dir: File.join(HARNESS_ROOT, "build", "mrb"),
                    raw_rb: ENV["HARNESS_SEND_RB"] == "1")
rescue Mrbc::Error => e
  raise e.message
end
