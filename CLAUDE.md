# R2P2-dev-harness

bash0C7 が個人で PicoRuby の装置を作るための知見と rake タスクを集約する repo。実機を焼いて検証する rake タスクは `rakelib/` と `tools/pico2w/`。
PicoRuby を USB 周辺機器にするライブラリ (`gems/`) と example (`examples/`) は、その上に載せた実例のひとつ。

- 設計と決定事項は [docs/spec.md](docs/spec.md) が single source of truth。実機の罠は §6 にまとめてある
- 残っている作業は GitHub issues (`gh issue list`)

## 作業の規律

- **完了の線引きは実機。** `rake test` (ホスト) が green でも、実機で走らせるまで「動いた」と書かない
- **`vendor/picoruby` は生成物。** commit しない。変更は `firmware-patches/` (build 中だけ当てる) か build_config の overlay で行う
- **Pico 2 W は Claude が触る。** `rake rp2040:build` / `flash` / `upload` / `run` / `reboot` は Bash から直接回せる
  (sandbox を外さずに USB へ届く)。人に頼むのは物理操作 (初回の BOOTSEL、wedge 時の USB 抜き差し、ボタン押下) と
  画面の目視だけ
- **serial を開くものは `tools/pico2w/tmo.rb` で時間を区切る。** wedge した board への open は macOS で返らない
- **board には `/home/app.rb` が置いてあり、起動時に自動実行されることがある。** その間 shell は黙る。rake の実機タスクは Ctrl-C で止めてから shell を使う
- **shell の生存は `tools/pico2w/shell_ok.rb` で見る。** `$>` プロンプトが返るかで判定し、bytes が返っただけでは生きていない
- firmware の build は数分かかる。長い処理は `nohup ... & disown` で切り離し、ログを scratchpad に書く
