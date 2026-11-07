# harness 監査表（hook・フラグ・スクリプトの実ファイル棚卸し）

cmd_264 ■3。2026-11-08 時点の実ファイルを読んで作った。推測で足していない。**読んだだけで、各 selftest が今通るかは実行していない**（「selftest 有」は試験ファイルが在るという意味）。この文書は番兵を増やさない。対策は書かない。

## 1. 数え方（何を1行とするか）

- **1行 = 実ファイル1本**。`scripts/` 直下の 33 本、`scripts/githooks/pre-push` 1 本。
- 実ファイルを持たない機構は、機構ごとに1行: `.claude/settings.json` の `permissions.deny`（48 パターン）を1行、`mods/` の4本を各1行。
- 1ファイルの中に**独立した off スイッチを持つ別機構**があれば、副行を足す（`pretooluse_yaml_guard.sh` の中の parent_cmd_done_gate）。
- 合計 **40 行** = 33 + 1 + 1 + 4 + 1。
- フラグ（スイッチ）は 3章に別表。行ではなく、行への対応として数える。
- 範囲外（数えていない）: リポジトリ直下の `shutsujin_departure.sh`・`first_setup.sh`・`setup.sh`、`lib/*.sh`、`tests/`。`lib/quote_masking.py` は git_push_block が使う共有部品で、独立の機構ではない。

### 列の意味

| 列 | 意味 |
|---|---|
| 段 | **起動のされ方**。`決定的` = 機械が自動で起こす（hook・watcher・起動手順）。`プロンプト依存` = 指示書に「呼べ」と書いてあるだけで、呼ぶかはエージェント次第。`人間` = 殿または将軍が手で走らせる |
| 関門 | `◎` = エージェントの行為を機械が止める（deny・block・reject）判定を、**作業経路に常設**している。**番兵に数える**。`○` = 判定を持つが、呼ばれたとき・起動時・配備時だけ働く（数えない）。`—` = 判定を持たない道具 |
| セッション内 | その番兵が防ぐ事故について、**エージェントのセッションの中**に防ぎ手があるか（番兵自身を含む）。✓/✗ |
| 後段の受け皿 | セッションの後ろに、取りこぼしを拾う機械の層があるか（番兵自身が後段ならその旨）。✓/✗ |
| 人 | 殿に届く経路（ntfy・標準出力・stderr）があるか。✓/✗ |
| fail-open | 判定の道具自身が壊れたとき、通す側に倒れるか。`はい`/`いいえ`（fail-closed）/`—` |
| off スイッチ | 無効にする手段。無いものは「ない」 |
| selftest | 専用の試験ファイル。無いものは「ない」 |

関門が `—` の行は、3列を `—` とする（番兵ではないので受け皿の有無を問わない）。`✗` は関門 `◎`/`○` の行にだけ付く。

## 2. 表

根拠は `ファイル:行`。`settings.json` = `.claude/settings.json`、`settings.yaml` = `config/settings.yaml`。

### 2.1 ◎ 番兵（作業経路に常設の関門）= 6 行

| # | 行 | 段 | 関門 | セッション内 | 後段の受け皿 | 人 | fail-open | off スイッチ | selftest | 根拠 |
|---|---|---|---|---|---|---|---|---|---|---|
| G1 | `scripts/pretooluse_yaml_guard.sh`（PreToolUse・Edit\|Write） | 決定的 | ◎ | ✓ deny を返す | ✗ ログ `logs/yaml_guard.log` は残るが、読む機械の層はない | ✓ fail-open と同一ファイルへの反復 DENY で ntfy | はい（内部エラーは通す＋ntfy） | `features.yaml_guard_enabled`（off\|observe\|enforce。未知値は off） | `tests/unit/test_pretooluse_yaml_guard.bats` | settings.json:36-40 / yaml_guard.sh:96-113（off）, :311-312・:396-398（fail-open）, :55・:409（ntfy・反復DENY）/ settings.yaml:2 |
| G2 | 副行: `pretooluse_yaml_guard.sh` 内の parent_cmd_done_gate（配下 task が未完了の cmd の done 化を止める） | 決定的 | ◎ | ✓ deny | ✗ observe 時は WOULD-DENY-PARENT-GATE をログへ書くのみ | ✓ 実 DENY は G1 の反復 DENY 警報に乗る | はい（G1 と共通） | `features.parent_cmd_done_gate_enabled`（off\|observe\|enforce）。`yaml_guard_enabled: off` でも連動して止まる | `tests/unit/test_parent_cmd_done_gate.bats` | yaml_guard.sh:119-132（flag）, :244-308（判定・enforce で deny）/ settings.yaml:5 |
| G3 | `scripts/pretooluse_git_push_block.sh`（PreToolUse・Bash） | 決定的 | ◎ | ✓ deny（`PUSH_APPROVED=1` がフック環境に無ければ） | ✓ 資格情報の分離（エージェントは GitHub へ書けない）。**リポジトリ外の事実で、本表では実測していない**。スクリプト自身が「止めるのは『うっかり』で、境界は GitHub 側」と記す | ✓ fail-open と反復 DENY で ntfy。push 自体は殿の手 | はい（内部エラーは通す＋ntfy） | `features.git_push_block_enabled`（off\|observe\|enforce） | `tests/unit/test_pretooluse_git_push_block.bats` | settings.json:46-50 / git_push_block.sh:11-16（限界の自己申告）, :75-87（off）, :120-131・:259-261（fail-open）, :229-240（deny）/ settings.yaml:4 |
| G4 | `scripts/stop_hook_inbox.sh`（Stop） | 決定的（完了通知の検出は文言一致なので、その部分は書き方に依存） | ◎ | ✓ 未読があれば Stop を block | ✓ `inbox_watcher.sh` の nudge と escalation が後段（`stop_hook_active` 時は block せず通す。:54-70 のコメントが「watcher が再配信する」と明記） | ✓ busy_guard の ntfy（watcher 側。`inbox_watcher.sh:199-201`）。間接 | はい（自己識別できなければ通す・python 失敗時は通す） | ない（外すには `settings.json` の `hooks.Stop` を消す） | `tests/unit/test_stop_hook.bats` | settings.json:19 / stop_hook_inbox.sh:38-40・:53-70（通す側）, :100-107（文言一致）, :193（block） |
| G5 | `scripts/githooks/pre-push`（git の pre-push。`core.hooksPath=scripts/githooks`） | 決定的（殿の端末で push が走るとき） | ◎ | ✗ エージェントのセッションでは走らない（push は殿の手元） | ✓ 自身が後段（送出差分を秘匿値の置場と値照合して拒否） | ✓ 拒否理由を stderr（値は出さない） | **いいえ**（置場が読めなければ拒否＝fail-closed） | ない（迂回用の環境変数は設けないと明記）。`--no-verify` は `permissions.deny` の G6 が止める | `tests/unit/test_pre_push_secret_hook.bats` | pre-push:5-15（方針）, :31-38・:229-235（拒否）/ `git config core.hooksPath` = `scripts/githooks`（**ローカル git 設定で追跡外**） |
| G6 | `.claude/settings.json` の `permissions.deny`（48 パターン） | 決定的 | ◎ | ✓ ツール呼び出しを拒否 | ✗ 拒否の記録を残す仕組みはない | ✗ 殿へ知らせる経路はない | —（静的な一覧。判定器を持たない） | ない（一覧から消す） | ない（`deny` 欄を読む試験は見つからず） | settings.json:58-106。内訳 = 破壊的コマンド 20（:59-78）／秘匿値の置場の読取封じ 25（:79-102 の 24 件と :106 の `Bash(*.config/multi-agent-shogun*)` 1 件。`Read(...)` と `cat`・`head`・`grep`・`cp`・`source` 等）／`git push --no-verify` 封じ 3（:103-105） |

> G6 の内訳 20 + 25 + 3 = 48 は、deny 配列の通し番号（0-19／20-43 と 47／44-46）で数えた。

### 2.2 ○ 判定を持つが、呼ばれたときだけ働く = 9 行

| # | 行 | 段 | 関門 | セッション内 | 後段の受け皿 | 人 | fail-open | off スイッチ | selftest | 根拠 |
|---|---|---|---|---|---|---|---|---|---|---|
| C1 | `scripts/inbox_watcher.sh`（busy_guard・auto_heal・key gate 等を内包。10 体分常駐） | 決定的 | ○ | ✗ セッション外で動く | ✓ 自身が後段（働き中の者へ /clear を送らない・死んだ CLI の自動復旧・escalation） | ✓ busy_guard 通知・auto_heal の escalation で ntfy | 部分的（busy_guard は設定が無ければ既定値で動く。:199） | `auto_heal.silent_heal_enabled`（auto_heal のみ）。busy_guard・nudge 本体には**ない** | `tests/unit/test_inbox_watcher_*.bats`・`test_busyguard_isolation.bats` ほか | inbox_watcher.sh:147-169（auto_heal 設定）, :199-232（busy_guard）, :1393（clear 前の busy 判定）, :2321（busy_guard_tick）, :2756・:2822（auto_heal）/ 起動: shutsujin_departure.sh:984 |
| C2 | `scripts/inbox_write.sh`（引数・型の検証 → 受信箱へ排他書込） | プロンプト依存（指示書が呼ばせる。stop hook・watcher からも呼ばれる） | ○ | ✓ 不正は exit 1 で呼んだ側に返る | ✗ | ✗ | いいえ（`set -e`） | ない | `tests/test_inbox_write.bats` | inbox_write.sh:23・:125・:263 |
| C3 | `scripts/dispatch.sh`（task YAML 検証＋書込＋通知を1コマンドに） | プロンプト依存（`instructions/karo.md`） | ○ | ✓ 検証違反は何も書かず exit 1 | ✗ | ✗ | いいえ | ない | `tests/unit/test_dispatch.bats` | dispatch.sh:14-17（検証）, :42 |
| C4 | `scripts/done.sh`（cmd/report/task の done 化・archive 移管） | プロンプト依存（指示書が呼ばせる） | ○ | ✓ task_id 不一致・終端 status は拒否 | ✗ | ✗ | いいえ | ない | `tests/unit/test_done.bats`・`test_done_task.bats` | done.sh:15-20（規則）, :29（die） |
| C5 | `scripts/preflight_check.sh`（起動前の依存検査） | 決定的（起動手順と watcher_supervisor から） | ○ | ✗ セッション前に走る | ✗ | ✓ 起動失敗として表に出る（exit 1 で起動中止） | いいえ（致命欠落は中止） | ない | `tests/unit/test_preflight.bats` | preflight_check.sh:2-5 / shutsujin_departure.sh:898・watcher_supervisor.sh:109 |
| C6 | `scripts/mcp_health_check.sh` | 決定的（起動手順） | ○ | ✗ | ✗ | ✓ 起動時の標準出力とログ `logs/mcp_health.log` | いいえ | ない | ない | mcp_health_check.sh:34-47 / shutsujin_departure.sh:1109。**注**: 見るのは codex の pane だけで、現行は全員 Claude のため 0 件検査（`logs/mcp_health.log` 末尾 `checked 0 codex panes`）。何も検査していない |
| C7 | `scripts/run_e2e_isolated.sh`（E2E を使い捨て tmux でだけ走らせる。生きた陣に触れさせない） | 人間（手で走らせる） | ○ | ✓ 生きた陣に繋がる状況を拒否 | ✗ | ✗ | いいえ | ない | `tests/unit/test_run_e2e_isolated_cleanup.bats`・`test_e2e_disposable_guard.bats` | run_e2e_isolated.sh:2-15 |
| C8 | `scripts/pre_deploy_verify.sh`（配備先が主ブランチでなければ abort） | 人間（**呼び元がリポジトリ内に無い**） | ○ | ✗ | ✗ | ✗ | いいえ（abort） | ない | `tests/unit/test_branch_policy_scripts.bats` | pre_deploy_verify.sh:34-48。呼び元の grep 結果 = 試験と自身のみ。**3列とも ✗** |
| C9 | `scripts/branch_drift_check.sh`（主ブランチ以外の長命ブランチを警告） | 決定的（設計=cron）だが**現状未配線** | ○ | ✗ | ✗ | ✗ | いいえ（`monitored_repos` が空なら SystemExit） | ない（cron を入れない=止まっている） | `tests/unit/test_branch_policy_scripts.bats` | branch_drift_check.sh:71（`[DRIFT]` を出すだけ）, lib/branch_policy.sh:70-82 / `crontab -l` に項目なし・`logs/branch_drift_check.log` なし・`settings.yaml`/`.example` に `branch_policy:` なし。**3列とも ✗** |

### 2.3 — 判定を持たない道具・注入・観測 = 25 行

関門 `—` につき3列は `—`。

| # | 行 | 段 | fail-open | off スイッチ | selftest | 根拠 / 備考 |
|---|---|---|---|---|---|---|
| T1 | `scripts/session_start_hook.sh`（SessionStart・persona 手順を注入） | 決定的（注入は確実。**従うかはプロンプト依存**） | はい（agent_id が取れなければ silent exit） | ない（外すには `settings.json` の `hooks.SessionStart` を消す） | ない | settings.json:8 / session_start_hook.sh:7・:28-30・:57-110 |
| T2 | `scripts/pretooluse_clear_idle.sh`（PreToolUse・idle フラグ削除） | 決定的 | はい（常に exit 0） | ない | ない（配線の存在検査のみ: `tests/unit/test_pretooluse_yaml_guard.bats:498`） | settings.json:30 / clear_idle.sh:6-11 |
| T3 | `mods/audit`（監査ログ。観測のみ） | 決定的（`cli.agents.*.mods` 宣言 → `--plugin-dir`） | はい（書込失敗はエージェントに届かない） | `settings.yaml` の `mods:` 欄を消して起動し直す | `tests/unit/test_mod_audit.bats`・`mods/audit/tests/audit.test.ts` | mods/audit/hooks/register.js:1-4 / lib/cli_adapter.sh:233-293 |
| T4 | `mods/banner`（役割表示。観測のみ） | 決定的（同上） | はい | 同上 | `tests/unit/test_mod_banner.bats`・`mods/banner/tests/banner.test.ts` | mods/banner/hooks/register.js:1-3 |
| T5 | `mods/status`（将軍の状態帯。観測のみ） | 決定的（将軍のみ宣言） | はい | 同上 | `tests/unit/test_mod_status.bats`・`mods/status/tests/status.test.ts` | mods/status/hooks/register.js:1-3 |
| T6 | `mods/toolrow`（ツール行の表示。表示のみ） | 決定的（全員宣言） | はい | 同上。表示の案切替は `mods/toolrow/hooks/config.js` | `tests/unit/test_mod_toolrow.bats`・`mods/toolrow/tests/toolrow.test.ts` | mods/toolrow/hooks/register.js:1-9 |
| T7 | `scripts/watcher_supervisor.sh`（watcher を生かし続ける） | 決定的 | —（監督役） | ない | `tests/unit/test_watcher_supervisor.bats`・`test_watcher_supervisor_dedup.bats` | shutsujin_departure.sh:984 / lib/watcher_lifecycle.sh:15 |
| T8 | `scripts/ntfy_listener.sh`（ntfy の入力を受信箱へ） | 決定的（起動手順） | —（常駐） | ない | `tests/unit/test_ntfy_ack.bats`・`test_ntfy_auth.bats` | shutsujin_departure.sh:1092-1094 |
| T9 | `scripts/ntfy.sh`（殿へ通知） | プロンプト依存（指示書）＋決定的（G1・G3 などから） | いいえ（topic が無ければ非0＝fail-loud） | ない（`features.reporting_mode` は通知の出し方の設定だが、読み手は 3章のとおり見当たらない） | `tests/unit/test_ntfy_sh.bats` | ntfy.sh:10-14 |
| T10 | `scripts/archive_report.sh`（report を日付つきで退避） | 決定的（done.sh から） | — | ない | `tests/unit/test_archive_report.bats` | done.sh が呼ぶ |
| T11 | `scripts/slim_yaml.sh` | プロンプト依存（指示書） | — | ない | `tests/unit/test_slim_yaml.bats` | slim_yaml.sh:1-10 |
| T12 | `scripts/slim_yaml.py`（T11 の本体） | 決定的（T11 から） | — | ない | 同上 | — |
| T13 | `scripts/build_instructions.sh`（指示書の組立） | 人間（Makefile） | — | ない | `tests/unit/test_build_system.bats` | — |
| T14 | `scripts/switch_cli.sh`（CLI・モデルの切替） | 人間 | — | ない | `tests/unit/test_switch_cli.bats` ほか | — |
| T15 | `scripts/agent_status.sh`（busy/idle の表示） | 人間 | — | ない | ない（専用なし。busyguard 等の試験が参照するだけ） | — |
| T16 | `scripts/ratelimit_check.sh`（レート制限の表示） | 人間 | — | ない | ない | — |
| T17 | `scripts/resume_auto_heal.sh`（auto_heal の停止解除） | 人間（**自動呼出し禁止**と冒頭に明記） | — | ない | `tests/test_resume_auto_heal.bats` | resume_auto_heal.sh:4-7 |
| T18 | `scripts/auto_merge_short_lived.sh`（短命ブランチを主ブランチへ merge） | 決定的（設計=cron）だが**現状未配線** | — | ない（cron を入れない=止まっている） | `tests/unit/test_branch_policy_scripts.bats` | 配線の欠如は C9 と同じ事実（cron なし・`branch_policy:` なし）。判定ではなく操作を行う道具のため関門に数えない |
| T19 | `scripts/setup_cron.sh`（T18・C9 の cron を表示・導入） | 人間 | — | ない | ない | `--install` するまで crontab は変わらない |
| T20 | `scripts/model_update_check.sh`（T21 の薄い包み） | 人間（**リポジトリ内に呼び元なし**。cron 例が冒頭にあるのみ） | — | `config/model_autoupdate.yaml` の `enabled: true` | ない | `logs/model_update_check.log` に 11-04・11-08 の実行跡。crontab は空 |
| T21 | `scripts/model_update_check.py`（新モデル版の検知・通知のみ） | 人間（T20 経由） | — | 同上 | ない | 自動適用はしない旨が冒頭に明記 |
| T22 | `scripts/cmd254_aggregate.py`（cmd_254 の前後比較集計・読取専用） | 人間 | — | ない | ない | — |
| T23 | `scripts/dashboard-viewer.py`（dashboard.md のブラウザ表示） | 人間 | — | ない | ない | — |
| T24 | `scripts/model_audit.sh`（各エージェントが実際に動いているモデルを、セッション記録の実測値で settings.yaml と突き合わせる。読取専用・cmd_264 ■1・5ea456d） | 人間（殿が手で実行。hook・watcher・settings.json に配線しない） | —（読むだけ。判定不能は終了コード 3 で返し 0 扱いにしない。不一致は 1） | ない | `scripts/model_audit_selftest.sh`（T25） | model_audit.sh:2-4・:30-35（終了コード）/ 呼び元: `docs/my_setup.md:262`（運用コマンドの記述のみ。スクリプトからの呼び出しなし） |
| T25 | `scripts/model_audit_selftest.sh`（T24 の試験。`mktemp -d` の jsonl で固定し trap で片付ける） | 人間 | — | ない | ない（試験そのもの） | model_audit_selftest.sh:2-12 |

### 行数の検算

行は G 6 + C 9 + T 25 = **40**。

| 内訳 | 行 | 数 |
|---|---|---|
| `scripts/` 直下の実ファイル | G1・G3・G4、C1-C9、T1・T2・T7-T25 | 3 + 9 + 21 = **33**（`ls scripts/*.sh scripts/*.py` = 33） |
| `scripts/githooks/pre-push` | G5 | 1 |
| `permissions.deny` | G6 | 1 |
| `mods/` | T3-T6 | 4 |
| 副行（G1 のファイルの中の別機構） | G2 | 1 |
| 合計 | | 33 + 1 + 1 + 4 + 1 = **40** |

## 3. フラグ（スイッチ）一覧

`config/settings.yaml`（追跡外）と `config/model_autoupdate.yaml`。

| フラグ | 値 | 動かす行 | 読み手 | 根拠 |
|---|---|---|---|---|
| `features.yaml_guard_enabled` | enforce | G1 | スクリプト | settings.yaml:2 / yaml_guard.sh:96-108 |
| `features.parent_cmd_done_gate_enabled` | enforce | G2 | スクリプト | settings.yaml:5 / yaml_guard.sh:119-132 |
| `features.git_push_block_enabled` | enforce | G3 | スクリプト | settings.yaml:4 / git_push_block.sh:75-82 |
| `features.reporting_mode` | exception | T9（通知の出し方）のはずだが、現行の読み手が見当たらない | スクリプトは読まない。`instructions/`・`CLAUDE.md`・`skills/` にも記述なし。残るのは `.opencode/agents/karo.md:637-645`（OpenCode 用の生成物）と `docs/my_setup.md:254` のみ | settings.yaml:3 |
| `feature_freeze.active` | false | なし | **読むコードなし**（記録と `docs/my_setup.md:258` の記述のみ） | settings.yaml:6-7 |
| `auto_heal.silent_heal_enabled` | true | C1（auto_heal の部分） | スクリプト | settings.yaml:12 / inbox_watcher.sh:167・:2918 |
| `enabled`（model_autoupdate） | true | T20・T21 | スクリプト | config/model_autoupdate.yaml:8 |

数値の設定（`auto_heal` の閾値・`assignment_grace`・`busy_guard`）は off スイッチではなく調整値のため、フラグには数えない（C1 の行に含む）。

`_enabled` で終わるフラグは settings.yaml に 4 つ（`yaml_guard_enabled`・`git_push_block_enabled`・`parent_cmd_done_gate_enabled`・`silent_heal_enabled`）。このうち関門（番兵）は先頭の 3 つ。`silent_heal_enabled` は復旧の動作であって関門ではない。

## 4. 番兵の実数と guard_capacity

**番兵 = 関門 `◎` の行 = 6**: G1 yaml_guard、G2 parent_cmd_done_gate、G3 git_push_block、G4 stop_hook_inbox、G5 pre-push、G6 permissions.deny。

旧 `guard_capacity: 10`（cmd_200 工程3）は「`_enabled` flag 9 件 + `stop_hook_inbox.sh` = 10」だった。その後の cmd_211・cmd_212 で、次の flag が機構ごと退役し、コードからの参照が無い（`scripts lib shutsujin_departure.sh .claude config instructions mods` を grep して 0 件）。

- `fleet_idle_notify_enabled`（8dc0bf3）
- `staged_ignore_guard_enabled`（39b648f）
- `secret_guard_enabled`（b718139）
- `notify_on_done_required_enabled`（9b78235）
- `parent_cmd_evidence_gate_enabled`（9b78235）
- `verified_evidence_required_enabled`（9b78235）

これで 9 − 6 = 3 flag（G1〜G3）+ stop hook 1 = 4 が旧定義の実数。ここへ、旧定義には無かった pre-push（cmd_213）と `permissions.deny` を、◎ の定義（作業経路に常設の関門）で加えると **6**。

**定義の選び方で数は変わる**（旧定義のまま = 4／本表の ◎ = 6／○ まで入れれば 15）。本表は ◎ を採る。定義の採否は家老・将軍の判断。`guard_capacity` を読むコードは無い（コメントとしてのみ存在）。

`config/settings.yaml` の `guard_capacity` は、2026-11-08 に定員を 6（本表の ◎ の実数）に置き直した（将軍の裁き）。新設 1 件につき退役 1 件の規則は変わらない。

## 5. 3列とも ✗ の行（対策は書かない）

- **C8** `scripts/pre_deploy_verify.sh` — 呼び元がリポジトリ内に無い。
- **C9** `scripts/branch_drift_check.sh` — cron 未導入・`branch_policy:` 設定なし。

## 6. 表を作る途中で見えた事実（判断せず記す）

- `config/settings.yaml.example:18` に退役済みの `reversibility_check_enabled` が残る（`scripts/` に実体なし）。
- `scripts/mcp_health_check.sh` は codex の pane しか見ず、現行（全員 Claude）では 0 件検査（C6）。
- `scripts/pretooluse_clear_idle.sh`・`scripts/session_start_hook.sh` に専用の試験が無い（T1・T2）。
- `core.hooksPath=scripts/githooks` はローカルの git 設定で、リポジトリには入っていない（G5）。
- `feature_freeze.active` を読むコードが無い（3章）。
