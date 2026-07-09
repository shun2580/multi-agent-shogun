# ループエンジニアリング設計案（cmd_060 / cmd_061）

殿ご指名タスク。本ドキュメントは調査・設計のみであり、コード/設定変更は一切含まない。
すべての事実は実ファイルの行番号を根拠とする（cmd_038 独立検証ルールに則り軍師自身が
再確認済み）。

**更新履歴**: cmd_060（2026-07-07 初版・調査＋設計）→ cmd_061（2026-07-07 §4-1/§5.2-bへ
殿裁可の客観5条件+fail-safeを織り込み、F007改訂文案を追記）→ cmd_061b（2026-07-07 束①:
§5.2-aへ判断タクソノミー正典化案(escalation_taxonomy.md新設案+用語集)、§5.2-eへTier2到達先
明確化案とfail-safe統一原則を追記）。

---

## 実装状態

| 節 | 状態 |
|---|---|
| §4-1 (git push承認ルール) | 実装済(cmd_061/cmd_063) |
| §4-2 (redo/詰まりHard Gate化) | 実装済(cmd_065) |
| §4-3 (基準の三重分散) | 実装済(cmd_063、escalation_taxonomy.md新設) |
| §4-4 (エスカレーション語の多義) | 実装済(cmd_063、用語集) |
| §4-5 (Tier2到達先) | 実装済(cmd_063、CLAUDE.md追記) |
| §4-6 (shogun本体リンク) | 実装済(cmd_065) |
| §4-7 (リトライ閾値rationale) | 文書化のみ実装済(cmd_065) |
| §4-8 (ハーネスループ統合) | 正式クローズ(cmd_065・見送り) |
| §5.3 (🚨放置再通知) | 実装済(cmd_065) |

## 0. 要旨

殿の認識——「本環境は自律ループ処理と、殿が判断すべきことへのエスカレーションを組み合わせた
human-in-the-loop システムである」——は **概ね Yes だが、重要な留保つき（部分的）** である。

- 一部の判断ゲート（auto_heal エスカレーション、inbox nudge タイミング）は **コードで強制**
  されている。
- 一方で、redo・詰まり検知の「N回失敗したら殿へ」というゲートは **karo.md のテキスト規約に
  すぎず、コードでは強制されていない**。LLM がコンテキスト圧迫下でこの規約を忘れれば
  無限ループになり得る構造的弱点である（詳細: §4-2）。
- 「エスカレーション」という語がインフラ層（nudgeの強度）と判断層（殿への相談）の
  **二つの異なる意味で無自覚に併用**されている（§4-4）。
- git push の「殿承認」ルール（F007）と、実際の運用（karo.md 比例分解ルール・
  dashboard.md の実績）は **食い違っている**。これは最も具体的で検証可能なギャップである
  （§4-1）。**cmd_061にて殿が裁可済み**: 「低リスク」を客観5条件で定義し、迷えば殿へ
  （fail-safe）とする設計に確定（§5.2-b）。実掟ファイルへの反映は別cmd待ち。

---

## 1. 殿の認識の検証

### 1.1 検証対象の認識
> 「この環境はループ処理もありつつ、殿が判断すべきことには必要に応じて指示・判断が
> 求められる」

### 1.2 根拠と判定

| 観点 | 事実 | 判定 |
|---|---|---|
| 自律ループの実在 | `scripts/inbox_watcher.sh` は各エージェントの inbox を `inotifywait`/`fswatch` で監視し続ける常駐daemon（L1553-1608）。`scripts/watcher_supervisor.sh` は `while true` (L95-98) でdaemonを再起動し続ける。`scripts/stop_hook_inbox.sh` は Claude Code の `Stop` hookとして、未読メッセージがあれば `{"decision":"block"}` を返しエージェントのターン終了を阻止する（L163-194）——これが「人間の入力なしに働き続ける」ことの中核機構。 | **Yes** |
| 殿の判断ゲートの実在 | CLAUDE.md の Action Required Rule（Shogun Mandatory Rules #7, "ALL items needing Lord's decision → dashboard.md 🚨要対応"）、Destructive Operation Safety Tier2 STOP-AND-REPORT表、karo.md の Redo Protocol（`instructions/karo.md:811` "2 redos → escalate to dashboard 🚨"）、詰まり検知ルール（`karo.md:1247` "殿の判断を仰ぐこと"）などが実在し、いずれも殿への相談を明文化している。 | **Yes** |
| 「必要に応じて」の運用一貫性 | ここに留保がある。§4 で詳述する複数の食い違い（push承認・エスカレーション語の多義性・記載の分散）により、「必要に応じて」の基準がドキュメント間で統一されていない。特に git push は F007（`instructions/common/forbidden_actions.md:10` "Ask the Lord first"）が明文化する一方、実際の運用（`karo.md:351-365` 比例分解ルール、dashboard.md の cmd_059/056/040 実績）は殿への都度確認なしに足軽が単独でpushしている。 | **部分的** |

### 1.3 結論
自律ループ機構と殿判断ゲートの両方が実装として存在する、という殿の認識の骨格は正しい。
ただし「必要に応じて」判断が要求される境界線は、ドキュメント間で不整合であり、一部は
コード強制、一部はLLMの自己規律のみに依存している。この不整合こそが本設計案の主対象。

---

## 2. 現状ループ機構の棚卸し

分類: **自律**=人間なしで進行 / **人間判断ゲート**=殿の判断・入力を要する / **ハイブリッド**=自律だが閾値超過で人間へ通知

| 機構 | ファイル:行 | 分類 | 概要 |
|---|---|---|---|
| inbox監視 daemon | `scripts/inbox_watcher.sh` (1618行) | ハイブリッド | inotifywait常駐監視。nudge段階: 0-2分=通常nudge(L1280-1287)、2-4分=Escape×2+Ctrl-C(copilot/kimiのみ、L1288-1291)、4分+=`/clear`強制(最大5分に1回、L1293-1318)。しきい値定義: `ESCALATE_PHASE1=120`/`PHASE2=240`/`COOLDOWN=300` (L120-122)。 |
| watcher常駐監視 | `scripts/watcher_supervisor.sh` (98行) | 自律 | `while true`(L95-98)でdaemon欠落を再起動。起動時`preflight_check.sh`失敗でexit 1(L85-88)。人間通知はしない（下流のpreflight自体が通知する）。 |
| 自動蘇生 | `scripts/inbox_watcher.sh` `check_and_heal_dead_cli()` (L1426-1548) | ハイブリッド | CLIクラッシュを2回連続観測で検知(`DEAD_CLI_STREAK>=2`, L1442-1443)、`switch_cli.sh`で自動再起動(L1517-1519)。 |
| 自動蘇生エスカレーション | 同上 `check_auto_heal_escalation()` (L1360-1420, 発火L1524-1536) | **コード強制**の人間判断ゲート | `logs/auto_heal_events.jsonl` を集計し、`config/settings.yaml` の `auto_heal:` (L1-5: window=10分/threshold=3回/cooldown=30分) を超えたら `ntfy.sh` で殿へ即通知。 |
| Stop hook（ターン継続強制） | `scripts/stop_hook_inbox.sh` (194行) | 自律 | 未読ありなら`{"decision":"block"}`(L163-194)でターン終了を拒否＝「人間の入力なしに働き続ける」の中核。shogunペインは対象外(L43-45)。 |
| SessionStart persona復元 | `scripts/session_start_hook.sh` (94行) | 自律 | `/clear`/compaction後にrole別復旧手順を`additionalContext`として注入(L38-84)。判断ロジックなし。 |
| Shogun口調強制 | `scripts/shogun_persona_hook.sh` (8行) | 自律 | shogunペインのみ`UserPromptSubmit`で戦国口調システムプロンプトを注入(L4-6)。 |
| 通知（殿→システム） | `scripts/ntfy.sh` (49行) | 人間判断ゲート | fail-loud設計：curl失敗/非2xxで`logs/ntfy.log`記録+exit 1(L36-46)。黙殺しない。 |
| 通知（システム→殿の応答受信） | `scripts/ntfy_listener.sh` (179行) | 人間判断ゲートの受信経路 | ntfyのstreaming受信(L144)を`queue/ntfy_inbox.yaml`へ記録しshogunを起こす(L171-173)。切断時`sleep 5`で再接続(L176-178)。 |
| 利用状況の可視化 | `scripts/ratelimit_check.sh` (673行) | 情報提示のみ | 通知・自動調整は一切なし。Codex/Claudeの閾値(L39-41, L481, L489)を算出するのみ。判断は人間/ダッシュボード側。 |
| 起動前提条件確認 | `scripts/preflight_check.sh` (130行) | ハイブリッド | 致命的依存欠如でexit 1(L30-88)、`ntfy.sh`でベストエフォート通知(L108-111)。 |
| モデル更新検知 | `scripts/model_update_check.py` (279行) | **意図的に人間判断ゲート** | ヘッダで明言「settings.yamlは絶対に書き換えない。switch_cli.shも呼ばない。適用は殿の承認後」(L12)。`notify()`(L197-215)はntfy+dashboard🚨記載のみで自動適用コードは皆無（grep確認済み）。memory記録([[model_autoupdate_policy]])と一致。 |
| 報告の独立検証 | `scripts/verify_report.sh` (89行) / `scripts/scope_check.sh` (108行) | 自律（QCゲート） | exit 0/1/2でPASS/FAIL/SKIPを返すのみ。人間通知はここでは行わず、呼び出し元(軍師/家老)が結果を見て判断。 |
| dashboard 🚨要対応 | CLAUDE.md Shogun Mandatory Rules #7 / `karo.md:646-652` | 人間判断ゲート（規約ベース） | 「殿の判断が必要な事象」を書く場所として一元化されているが、**「何が該当するか」の基準は複数箇所に分散**（§4-3）。 |
| `/loop` skill（ハーネス側） | Claude Code 組込みskill | 自律（人間が起動、以後自律継続） | 一定間隔または自己ペースでpromptを再実行。起動は必ず人間発（opt-in）。本プロジェクト独自のtmux+inbox機構とは**別系統**——karo/ashigaru/gunshiの永続ループは`/loop`ではなく、tmuxペインの永続セッション＋Stop hookブロック＋inbox_watcher nudgeで実現されている。 |
| `ScheduleWakeup`（ハーネス側） | Claude Codeツール | 自律（動的スリープ） | 60〜3600秒の範囲で次回起床を予約。ハーネス側でハードキャップされたstop機構(`stop:true`)を持つ。本プロジェクトのcron/待機処理はこれを採用しておらず、`watcher_supervisor.sh`の`sleep 5`ポーリング(L97)や`inbox_watcher.sh`の`inotifywait --timeout 30`(L1553)という独自実装で代替している——ハーネス標準機構とプロジェクト独自機構が**統合されていない2系統**として併存。 |

---

## 3. 判断タクソノミー

「どの分岐が殿の判断を要し、どれが自律進行してよいか」を一枚に統合する（既存の
Forbidden Actions / Destructive Operation Safety / Action Required Rule との対応込み）。

| # | 分岐の種類 | 現行の扱い | 根拠 | 強制方式 |
|---|---|---|---|---|
| 1 | 破壊的操作 D001-D008（`rm -rf`外部, force push, `git reset --hard`等） | **絶対拒否**（殿判断すら経ない即REFUSE） | CLAUDE.md Destructive Operation Safety Tier1 (269-278行相当) | LLM自己規律のみ（コード上のガードレールなし＝エージェントの倫理規約に依存） |
| 2 | Tier2 STOP-AND-REPORT（>10ファイル削除・プロジェクト外変更・未知URL・破壊性不明） | 殿へ**要確認**（ただし文言は"notify Karo/Shogun"であり殿到達を明言せず） | CLAUDE.md Destructive Operation Safety Tier2 (280-287行相当) | LLM自己規律のみ |
| 3 | git push の承認 | **文書間で矛盾**（詳細§4-1）。F007は「殿の事前承認必須」、karo.md比例分解ルールは「低リスクは単一足軽サブタスク+軍師QC1回で完結、殿確認は明記なし」 | `instructions/common/forbidden_actions.md:10`(F007) vs `karo.md:351-365` | 一部コード(`scope_check.sh`でpush先ファイル確認)だが承認有無はコード検証対象外 |
| 4 | Redo（足軽の成果物が不十分） | 2回まで自律redo、3回目で殿へ | `karo.md:811` | **テキスト規約のみ**（カウンタはコードになし） |
| 5 | 詰まり検知（足軽/軍師無応答） | 自己回復を2回試行、失敗継続で殿へ | `karo.md:1229`, `karo.md:1247` | **テキスト規約のみ** |
| 6 | 自動蘇生（CLIクラッシュ） | 10分内3回蘇生で殿へntfy | `scripts/inbox_watcher.sh:1360-1420`(`config/settings.yaml`の`auto_heal:`) | **コード強制**（jsonlログ+カウンタ） |
| 7 | OSS PR判断（重大な設計不一致） | 「Shogunへエスカレーション」——**殿ではなくShogunエージェントまで** | `karo.md:1122-1127` | LLM自己規律のみ。Shogunがさらに殿へ上げるかは未規定（曖昧） |
| 8 | スキル化候補 | dashboard記載＋🚨要対応で殿承認を仰ぐ | `karo.md:716-721` | テキスト規約 |
| 9 | タスクの人/AI振り分けが曖昧 | 「Ask Lord」 | `shogun.md:212`, `shogun.md:284` | テキスト規約 |
| 10 | バッチ処理①-⑥のbatch1 QCゲート | 「Shogun QC」——殿本人への相談かエージェント内判断か不明記 | CLAUDE.md Batch Processing Protocol (230-253行相当) | **曖昧**（誰が最終判断者か未定義） |
| 11 | モデル自動更新の適用 | **常に殿承認必須**（自動適用コード自体が存在しない） | `scripts/model_update_check.py:12,197-215` | コード強制（適用経路が物理的に存在しない） |
| 12 | dashboard 🚨要対応の一般カテゴリ | 「殿の判断が必要な事象」全般（copyright/tech choice/blocker/question等） | CLAUDE.md #7 + `karo.md:646-652`のチェックリスト | テキスト規約。**該当基準がCLAUDE.md(抽象的)とkaro.md(具体列挙)とshogun.md(別の具体例)で三重に分散** |
| 13 | Northstar違反の疑い | 軍師が"⚠️ North Star violation"として報告に明記 | `instructions/gunshi.md:155` | テキスト規約（軍師の自己申告のみ） |

---

## 4. ギャップとリスク

深刻度: 🔴高 / 🟡中 / 🟢低

### 4-1. 🔴 git push 承認ルールの矛盾（実運用との乖離）
- `instructions/common/forbidden_actions.md:10` (F007): 「`git push` without the Lord's explicit approval」を全エージェント共通で禁止。`instructions/common/task_flow.md:197`も同旨。
- しかし `instructions/ashigaru.md:63-64` のワークフローは、足軽が記事/ドキュメント完成時に**都度の殿確認なしで** commit+push することを標準ステップとして定義している。
- `karo.md:351-365`（比例分解ルール, cmd_058）はこれをさらに追認し、「低リスクpush（published:false下書き等）は足軽の単一サブタスク内で完結、軍師QC1回で締める」と明記——ここに**殿承認**の文言は一切ない。
- dashboard.md の実績を見ると運用は不統一: cmd_057は「(殿許可)」と明記されているが、cmd_059/cmd_056/cmd_040 のpushはいずれも「軍師QC PASS」のみで殿許可の記載がない。
- **リスク**: 新規参加者やLLMがF007を字義通り解釈すると、実際の運用フローと矛盾し混乱する。あるいは逆に「今まで通り」で軍師QCのみを続けると、F007が形骸化する。どちらの解釈が正か、文書上の裁定がない。
- **cmd_061 追記（2026-07-07 殿裁可）**: 案A（低リスクpushは軍師QC1回で足軽実施可）を採用しつつ、
  「低リスク」をAIの主観判断に委ねず客観5条件で定義する方針が裁可された。設計内容は
  §5.2-b に具体化した。**本ドキュメントの設計レベルでは解消済み。forbidden_actions.md 等の
  実掟への反映は殿の最終確認を経て別cmdで実施**（本タスクでは実掟ファイルは変更しない）。

### 4-2. 🔴 「N回失敗で殿へ」ゲートがコード強制されていない
- Redo(2回で殿へ、`karo.md:811`)・詰まり検知(2回で殿へ、`karo.md:1247`)は、**カウンタがコードに存在しない**。家老（LLM）が自分でカウントし、規約を思い出して実行する前提。
- 対照的に、自動蘇生エスカレーション（3回/10分、`inbox_watcher.sh:1360-1420`）は `logs/auto_heal_events.jsonl` を実際にbashで集計しており、LLMの記憶に依存しない。
- **リスク**: コンテキスト圧迫・`/clear`直後・compaction直後などLLMの記憶が不確かなタイミングで、同じ対処が3回・4回と繰り返されても誰も気づかない構造的弱点。cmd_017自身が「自己回復を無限に試みてはならない」と警告しているのは、この弱点を運用側が既に懸念していた証左。

### 4-3. 🟡 「殿へ要エスカレーション」の基準が三重に分散
- CLAUDE.md #7: 抽象的（"ALL items needing Lord's decision"、具体例なし）。
- `karo.md:646-652`: 具体列挙（skill candidates, copyright issues, tech choices, blockers, questions）。
- `shogun.md:212,284`: 別の具体例（タスクのAI/人振り分けが曖昧な場合、破壊的PRの拒否等）。
- 単一の正典（canonical taxonomy）が存在せず、3ファイルのいずれかを読み落とすと基準が欠落する。
- **cmd_061b 追記（2026-07-07 殿追指示・束①-1）**: `instructions/common/escalation_taxonomy.md`
  新設による正典化案を §5.2-a に具体化した。**設計レベルで解消済み**（実ファイルへの反映・
  `build_instructions.sh`実行は殿の最終確認後、別cmdで実施）。

### 4-4. 🟡 「エスカレーション」という語の多義性
- インフラ層: `inbox_watcher.sh`のnudge強度アップ（2分/4分で強い介入に切替える）を指して使われる。
- 判断層: dashboard🚨・ntfyを通じた「殿への相談」を指して使われる。
- 同じ語が両方に無自覚に使われており（例: karo.mdの複数箇所）、設計議論において混同を招きやすい。本ドキュメントでは前者を「nudge強度」、後者を「判断エスカレーション」と呼び分けて区別した。
- **cmd_061b 追記（2026-07-07 殿追指示・束①-2）**: 用語集案を §5.2-a-4 に具体化した。
  **設計レベルで解消済み**。

### 4-5. 🟡 Tier2 STOP-AND-REPORTの到達先が不明確
- CLAUDE.md Destructive Operation Safety Tier2表のヘッダは「STOP-AND-REPORT (halt work, notify Karo/Shogun)」——**殿（人間）まで必ず届くとは明言していない**。
- Karo/Shogunエージェント止まりで完結してよい設計なのか、それとも常に人間まで転送すべきなのか、文書上未確定。
- **cmd_061b 追記（2026-07-07 殿追指示・束①-3）**: 「迷えば必ず殿まで到達」の追記文案を
  §5.2-e に具体化し、push承認と同一のfail-safe統一原則として位置づけた。**設計レベルで
  解消済み**（実ファイル(CLAUDE.md)への反映は別cmd）。

### 4-6. 🟡 shogun.mdが自分自身のAction Required Ruleを引用していない
- CLAUDE.md #7とkaro.mdのチェックリストはあるが、`shogun.md:48`「Read dashboard.md and report to Lord」という指示自体は、🚨要対応セクションを優先的に確認せよという明文の紐付けを欠く。読み落としリスク。

### 4-7. 🟢 リトライ閾値が不統一でrationaleが不明
- nudge強度: 2分/4分（時間ベース）。
- 自動蘇生: 3回/10分（回数＋時間窓）。
- redo: 2回（純粋回数）。
- 詰まり検知: 2回（純粋回数）。
- それぞれ別の設計者・別のcmdで個別に定められており、なぜ2でなく3か、なぜ時間窓でなく回数か、統一的な根拠が文書化されていない。実害は小さいが、将来閾値を調整する際に一貫性のある変更が困難。

### 4-8. 🟢 ハーネス標準ループ機構（`/loop`・`ScheduleWakeup`）とプロジェクト独自機構の非統合
- 本プロジェクトの永続ループ（tmuxペイン常駐＋Stop hookブロック＋inbox_watcher nudge）はハーネス標準の`/loop`skillや`ScheduleWakeup`を使っていない独自実装。
- 実害は現状ないが、ハーネス側の設計知見（例: ScheduleWakeupのプロンプトキャッシュ5分TTLを意識した間隔選定、ポーリング禁止の明確な原則）がプロジェクト側の`sleep 5`ポーリング(`watcher_supervisor.sh:97`)や`inotifywait --timeout 30`(`inbox_watcher.sh:1553`)に反映されているか、意識的な比較検討がされた形跡がない。

**【cmd_065にて正式クローズ・2026-07-07】** 見送りを結論とする。理由:
(a) 現行inbox_watcher.shのnudgeタイミング・watcher_supervisor.shのsleep 5ポーリングは
実害報告なく安定稼働中(cmd_017以降、無限ループ事故の報告なし)。
(b) ScheduleWakeup・/loopはエージェント内ツールでありtmux常駐プロセス(bashデーモン)の
置き換えには設計思想が異なる(前者はLLMエージェントのターン内で完結する起床予約、
後者はOS常駐プロセス)。移行の実利益(プロンプトキャッシュ節約等)は本プロジェクトの
用途では小さいと判断。将来nudgeタイミングの見直しが必要になった場合のみ再評価する。

---

## 5. あるべき設計案

### 5.1 設計原則
既存の判断ゲートを「コード強制ゲート（Hard Gate）」と「規約ゲート（Soft Gate）」に明示的に
区別し、**Soft GateのうちLLMの記憶依存度が高いものから優先的にHard Gate化**する。
新規ゲートを増やすのではなく、既存の矛盾（§4-1）と分散（§4-3）を整理・一元化することを
優先する（コスト最小・リスク最大の箇所から着手）。

### 5.2 具体提案

**a. 判断タクソノミーの正典化（§4-3の解消）— 【殿追指示・束①-1 2026-07-07・cmd_061b】**

**a-1. ビルド機構の実態確認（根拠）**

`scripts/build_instructions.sh:112-119` を実際に読むと、`instructions/common/protocol.md`・
`instructions/common/task_flow.md`・`instructions/common/forbidden_actions.md` の3ファイルは
固定の`cat`順序で全ロール×全CLI（claude/codex/copilot/kimi/opencode）の
`instructions/generated/*.md` に**自動的に展開・共有**される（`build_instruction_file()`関数、
L60-107）。`instructions/common/forbidden_actions.md:9`(F006)自身が「source templates
（CLAUDE.md・`instructions/common/*`・`instructions/cli_specific/*`・`instructions/roles/*`）
を編集し`build_instructions.sh`を実行せよ、生成物(`instructions/generated/*.md`)を直接
編集するな」と明記しており、この`common/*`への追加が正典化の正規ルートである。

**a-2. 提案: `instructions/common/escalation_taxonomy.md` の新設**

本ドキュメント §3 の判断タクソノミー表（骨子として流用可）と、束①-2の用語集（下記b参照）を
まとめた `instructions/common/escalation_taxonomy.md` を新設し、`build_instructions.sh` の
`cat`シーケンスに `forbidden_actions.md` と並べて追加する（実装は別cmd。本タスクでは
設計提案のみ、実ファイルは変更しない）。これにより自動生成される
`instructions/generated/*.md`（全ロール×全CLI）には自動的に正典が展開される。

**a-3. 既知の限界（重要な留保）**

ただし実際にCLIエージェントが起動時に読むファイルは、CLAUDE.md Session Start手順が
指す `instructions/{role}.md`（例: `instructions/karo.md` 全1248行超）という**手書きの
本体ファイル**であり、これは`instructions/generated/{role}.md`（`roles/{role}_role.md`+
common/*+cli_specific/*から自動合成される別ファイル、例: `instructions/generated/karo.md`
777行）とは**別物**である（`build_instruction_file()`は`original_file`から前文（YAML
front matter）のみ抜き出し、本体は`roles/*_role.md`から合成するため）。したがって
`instructions/common/escalation_taxonomy.md`を新設しても、`instructions/karo.md`・
`instructions/shogun.md`・`instructions/gunshi.md`という手書き本体ファイル群には
**自動反映されない**。現実的な対応として、各手書き本体ファイルの該当箇所（karo.md:646-652、
shogun.md:212,284等）に「正典は`instructions/common/escalation_taxonomy.md`参照」という
1行の参照リンクを手動追記し、具体列挙自体はそちらへ寄せる、という二段構えが必要になる
（実ファイル変更は別cmdで殿裁可後）。

**a-4. 用語集（束①-2、§4-4の解消）**

`escalation_taxonomy.md`には以下の用語定義を含める:

| 用語 | 意味 | 層 | 具体例 |
|---|---|---|---|
| **nudge強度**（インフラ層） | inbox監視daemonが未応答エージェントを起こす際の介入の強さの段階 | システム内部の配送メカニズム | `inbox_watcher.sh`の0-2分=通常nudge/2-4分=Escape×2/4分+=`/clear`強制 |
| **判断エスカレーション**（人間判断層） | エージェントが自律判断を止め、殿の意思決定を仰ぐこと | 人間とのインターフェース | dashboard.md 🚨要対応記載・`ntfy.sh`通知・Tier2 STOP-AND-REPORT |

この2層は独立した概念であり、「nudge強度が上がる」ことと「殿へ判断エスカレーションする」
ことは連動する場合もあれば（例: auto_heal閾値到達時のntfy）、しない場合もある（例:
`/clear`強制は純粋なnudge強度の最終段階で、殿への相談を伴わない）。既存文書ではこの2つを
同じ「エスカレーション」という語で無自覚に併用しているため、今後の追記では本用語集に従い
明確に書き分ける。

**b. git push 承認ルールの裁定（§4-1の解消）— 【殿裁可済 2026-07-07・cmd_061】**

殿の裁可方針: 案A（低リスクpushは軍師QC1回で足軽実施可）を土台としつつ、「低リスク」を
AIの主観判断に委ねず**客観的に確認できる5条件の充足**として定義する。5条件を全て満たせば
自動push可、一つでも欠ければ殿へエスカレーション。判定に迷えば必ず「高リスク扱い＝殿へ」を
既定とする（fail-safe）。

**b-1. 客観的低リスク5条件の判定表**

| # | 条件 | 判定方法 | 機械確認可否 |
|---|------|----------|-------------|
| 1 | frontmatter `published:false` 等、非公開下書き状態であること | 対象ファイルのfrontmatterを`grep`/YAML parseで直接確認 | **機械確認可能** |
| 2 | 変更が下書き/ドキュメント(`.md`等)のみで、コード・設定・CI・秘密情報を含まないこと | 変更ファイルパスの拡張子・ディレクトリを`scope_check.sh`の`allowed_paths`機構で確認 | **機械確認可能**（既存`scope_check.sh`を拡張活用） |
| 3 | 通常push（`--force`不使用）であること | 実行したgitコマンドに`--force`/`-f`が含まれないことを確認（D003の延長） | **機械確認可能** |
| 4 | 金銭・アフィリエイト・法的主張・個人情報に関わる新規の外向き主張を含まず、`published`を`true`に変更しないこと | (a) `published`値がtrueへ変化していないかは機械確認可能。(b) 「新規の外向き主張を含むか」は文章の意味内容判定であり、完全自動化は困難 | **部分的**（(a)機械確認可能／(b)僅かに意味判断が残る） |
| 5 | cmd宣言スコープ内であること | `scope_check.sh`（`allowed_paths`/`target_path`）で機械確認 | **機械確認可能** |

**b-2. 迷えば高リスク既定（fail-safe）の明文化**

5条件のうち1つでも欠ける場合、または条件4(b)のように意味判断が必要な項目で軍師/足軽が
確信を持てない場合は、**自動的に「高リスク扱い＝殿へエスカレーション」を既定値とする**。
設計意図: 誤判定は必ず「殿を無駄に煩わせる（安全な失敗）」方向にのみ転び、「黙って公開事故
（危険な失敗）」には決して転ばないよう、判定基準は非対称に安全側へ倒す。

**b-3. 機械化の範囲の切り分け**

条件 #1・#2・#3・#5 は既存の`scope_check.sh`（allowed_paths/target_path確認）や単純な
文字列/フラグ確認で**完全に機械判定可能**であり、将来的にはpush前の自動ゲートスクリプトへ
組み込む余地がある（実装は別cmd・殿裁可後）。条件 #4 のみ、(a)published値の機械確認と
(b)「新規の外向き主張の有無」という意味論的判断が併存し、(b)は本質的に軍師の読解・QC
判断に依存し続ける——ここが本設計における自動化の限界点であり、無理に完全自動化を
目指すべきではない（誤って自動push可と判定するリスクの方が、軍師QCの一手間より高くつく）。

**b-4. F007改訂文案（設計案・実ファイル未変更）**

以下は`instructions/common/forbidden_actions.md`のF007を改訂する場合の文案である。
**本タスクでは設計ドキュメント内の提示にとどめ、実ファイルは変更しない。**

> **F007（改訂案）**: `git push` は原則として殿の事前承認を要する。ただし以下5条件を
> すべて客観的に満たす場合に限り、足軽が単一サブタスク内で実行し軍師QC1回で完結してよい
> （殿の都度承認は不要）:
> 1. frontmatter `published:false` 等、非公開下書き状態であること
> 2. 変更が `.md` 等のドキュメントのみで、コード・設定・CI・秘密情報を含まないこと
> 3. 通常push（`--force`不使用）であること
> 4. 金銭・アフィリエイト・法的主張・個人情報に関わる新規の外向き主張を含まず、
>    `published` を `true` に変更しないこと
> 5. cmd宣言スコープ内（`scope_check.sh`確認範囲内）であること
>
> いずれか1つでも欠ける、または判定に確信が持てない場合は、既定として「高リスク」とみなし
> 殿の事前承認を必須とする（fail-safe: 迷いは常に高リスク側へ）。

**karo.md 比例分解ルールとの整合**: `karo.md:351-365`の「低リスク／高リスク」の線引きは
現状、軍師/足軽の主観的判断に委ねられていた。上記5条件はこの「低リスク」の定義を客観化する
ものであり、比例分解ルール自体の構造（低リスク＝単一サブタスク+単一QC、高リスク＝多段QC）
を変更するものではない。比例分解ルール側の「低リスク」の語に、本改訂案の5条件を紐付ける
形で整合させる（karo.mdの実際の追記は別cmdで殿裁可後）。

**c. Redo/詰まり検知のHard Gate化（§4-2の解消、コード変更を伴う将来フェーズ）**
`logs/auto_heal_events.jsonl`と同様の構造で `logs/redo_events.jsonl` / `logs/stuck_events.jsonl`
を新設し、`inbox_watcher.sh`の`check_auto_heal_escalation()`に相当する軽量スクリプトで
「同一task_idへの2回目のredo」「同一エージェントへの2回目の詰まり検知」をカウントし、
閾値到達時に自動でntfyを発火する設計とする。家老の記憶ではなくログの実測値がゲートを
駆動するため、コンテキスト圧迫時にも取りこぼさない。
（**本cmdでは設計提案のみ。実装は別cmdで殿の裁可後に着手**）

**d. 用語の整理（§4-4の解消）**
「nudge強度」（インフラ層）と「判断エスカレーション」（人間判断層）の書き分けは §5.2-a-4
（用語集案）に統合した。既存文書の一括置換は本cmdの範囲外（調査・設計のみ）。

**e. Tier2到達先の明確化（§4-5の解消）— 【殿追指示・束①-3 2026-07-07・cmd_061b】**

CLAUDE.mdのDestructive Operation Safety Tier2表（STOP-AND-REPORT）は「notify Karo/Shogun」
としか書かれておらず、殿（人間）まで必ず届くかが不明確だった（§4-5）。以下の追記文案を
提案する（**実ファイル(CLAUDE.md)は書き換えない。設計案として提示のみ**）:

> **Tier2 STOP-AND-REPORT 追記案**: 「Karo/Shogunは一次判断を行ってよいが、破壊性・
> 影響範囲について**判断に迷う場合、または不明な場合は、必ず殿(ntfy)まで到達させること**。
> Karo/Shogunの自己判断のみで握り潰し、殿への到達を省略してはならない。」

**fail-safe思想としての位置づけ**: これは §5.2-b-2（git push承認の「迷えば高リスク＝殿へ」）
と**同一のfail-safe原則**である——すなわち「判定に確信が持てない場合は、常に人間判断ゲート側
へ倒す」という設計思想を、push承認だけでなくTier2破壊的操作の到達先判断にも一貫して適用する。
本ドキュメント全体を通じた統一原則として、§5.1設計原則に以下を追記する:

> **fail-safe統一原則**: 本設計案が提案する全ての判定ロジック（push承認5条件・Tier2到達先・
> 将来のHard Gate化含む）は、「判定に迷う／確信が持てない場合は必ず人間判断ゲート側に倒す」
> という単一の思想で統一する。安全な失敗（殿を煩わせる）は許容し、危険な失敗（黙って進行）
> は許容しない。

実装（CLAUDE.mdへの文言追記）は軽微でコード変更を伴わないが、実ファイル反映は殿の最終確認後、
別cmdで着手する。

**f. 段階導入案（phase）**
- **Phase 1（本cmd直後、文書のみ・低コスト）**: (a)判断タクソノミー正典化、(b)F007裁定、
  (d)用語整理、(e)Tier2到達先明確化——いずれもMarkdown追記/整理のみで着手可能。
- **Phase 2（軽量コード変更・別cmdで殿裁可後）**: (c) redo/stuck-detectionのjsonlログ化と
  カウンタスクリプト新設。既存の`inbox_watcher.sh`のnudgeタイミングロジックには触れない
  （既に堅牢に動作しているため変更リスクを取らない）。
- **Phase 3（任意・大規模、要検討）**: `watcher_supervisor.sh`の`sleep 5`ポーリングや
  `inotifywait --timeout`待機を、ハーネス標準の`ScheduleWakeup`的な設計思想（キャッシュ
  ウィンドウを意識した間隔選定、無駄なポーリングの回避原則）と比較検討し、置き換える
  価値があるか評価する。優先度は低い（現行実装に実害の報告はない）。

### 5.3 停止条件・フォールバックの明文化提案
現状、dashboard.md 🚨要対応セクションに記載された項目が**殿に読まれないまま放置された場合の
再通知・エスカレーション昇格ルールが存在しない**（cmd_028のような手動清掃はあるが、
未読のまま古くなった🚨項目を自動的に再度目立たせる仕組みがない）。
提案: 🚨要対応項目に`created_at`を付与し、一定時間（例: 24時間）応答がなければ
`ntfy.sh`で再通知する仕組みをPhase 2の候補に含める。これは新規のHard Gateだが、
既存のntfy fail-loud設計（`scripts/ntfy.sh:36-46`）と同じ思想の延長であり実装コストは低い。

---

## 付録: 主要根拠ファイル一覧

- `CLAUDE.md`（Session Start手順・Report Flow・Destructive Operation Safety・
  Batch Processing Protocol・Action Required Rule）
- `instructions/shogun.md` (L212, L284, L48, L332-338)
- `instructions/karo.md` (L323-373 比例分解ルール, L610-652 Action Needed/Checklist,
  L785-812 Redo Protocol, L1231-1248 詰まり検知)
- `instructions/ashigaru.md` (L63-64 git_push workflow step)
- `instructions/common/forbidden_actions.md` (F007)
- `instructions/common/task_flow.md` (L197 Pre-Commit Gate)
- `instructions/gunshi.md` (L155 North Star violation flag)
- `scripts/inbox_watcher.sh` (L120-128, L1268-1420, L1426-1548)
- `scripts/watcher_supervisor.sh` (L85-98)
- `scripts/stop_hook_inbox.sh` (L43-45, L50-116, L163-194)
- `scripts/session_start_hook.sh` (L38-84)
- `scripts/shogun_persona_hook.sh` (全8行)
- `scripts/ntfy.sh` (L36-46) / `scripts/ntfy_listener.sh` (L144-178)
- `scripts/ratelimit_check.sh` (L39-41, L481, L489)
- `scripts/preflight_check.sh` (L30-121)
- `scripts/model_update_check.py` (L12, L182-215)
- `scripts/verify_report.sh` / `scripts/scope_check.sh`
- `scripts/build_instructions.sh` (L60-119 `build_instruction_file()`、common/*の全ロール
  ×全CLI展開機構)
- `config/settings.yaml` (L1-5 auto_heal)
- `dashboard.md`（cmd_053/054/057/058/059/040 の実績記録によるエスカレーション運用の実例）
- Claude Codeハーネス: `/loop` skill, `ScheduleWakeup` ツール定義（本セッションのシステム
  プロンプトより）
