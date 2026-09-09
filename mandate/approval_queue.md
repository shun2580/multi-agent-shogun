# approval_queue.md — 承認待ちキュー(戻せない操作)

**本ファイルの位置づけ**: 戻せる操作(ローカル編集・ブランチコミット・テスト実行・docs生成)は
自動進行・個別報告不要とする一方、戻せない操作(push・公開・published:true化・DB破壊的変更・
外部送信・ファイル削除)は実行せず、本ファイルへ追記して次タスクへ進む運用のためのキューである。

**エントリ形式(必須)**:

```
ID | 日付 | 操作内容 | 理由 | doubt: 承認判断のために見るべき箇所 | 状態(pending/approved/rejected)
```

- `doubt` 欄は必須。エージェント自身が「どこを確認すれば承認できるか」を申告すること
  (対象ファイル・差分・実行コマンド・影響範囲など、殿またはレビュアーが最短で判断できる材料)。

**上位規律の非上書き(CRITICAL)**: 本ファイルへの追記は D001-D008(Destructive Operation Safety)
の代替経路では**ない**。Tier1(D001-D008)該当操作はキューにも積まず、従来どおり拒否・報告する。
本キューが対象とするのは、D001-D008には該当しないが不可逆性を持つ操作(push・公開処理等)のみ。

**恒久例外(非緩和・cmd_145殿裁定追加②)**: 設計承認(CoDD Wave境界)の殿必須は、本キューによる
承認一元化・消化運用の対象**外**であり、恒久的に維持する。設計承認は従来どおり各Wave境界で
殿の都度承認を得ること。本キューへ積んで消化する運用に置き換えてはならない。

**セッション終了前の消化(cmd_145殿裁定追加③)**: 本キューは**セッション終了前に必ず1回消化する**
(殿の裁定へ回す、または明示的な持ち越し許可を得る)。pendingのまま持ち越してよいのは殿の
明示判断があった場合のみ。実務手順は`instructions/shogun.md`・`instructions/karo.md`の
陣仕舞い手順を参照。

**殿の判断回数の計測(cmd_155)**: エントリの状態欄を`pending`→`approved`または`pending`→
`rejected`へ更新する際は、その場で必ず以下を実行せよ(既存の`scripts/log_timing_event.sh`の
拡張・新規計測機構は不要):

```
bash scripts/log_timing_event.sh lord_judgment_recorded <cmd_id> "" <agent> \
  --source=<agent> --extra=approval_queue_approved:<AQ-ID>
```

却下時は`--extra=approval_queue_rejected:<AQ-ID>`とする。検出規則・工程定義の全体像は
`mandate/verifiers.md`を参照。

---

## 本サブタスク時点の状態

本ファイルは cmd_145 Part2a の範囲(mandate/4ファイルの新規設置)として、
骨格(本ヘッダー・エントリ形式・運用ルール)のみを整えたものである。
運用開始(instructions側の分岐反映・完了時手順への組込み)はsubtask_145_part2b3で実施済み。

## キュー

- ID: AQ-001 | 日付: 2026-08-04 | 操作内容: `mandate/judgment_model.md` 初版の指揮層必読化発効
  (将軍・家老・軍師のSession Start手順への読込組込み自体はinstructions側で実施済み。
  本エントリは「内容を承認済みルールとして運用開始してよいか」を議題とする) |
  理由: cmd_145殿裁定追加④「新原則は殿の承認待ちを初版自体にも自己適用する」に従い、
  実施(内容の権威づけ)前に殿レビューへ回すもの |
  doubt: (a) 原則14件(2026-08-05実測、`grep -c "^## 原則" mandate/judgment_model.md`)
  それぞれの出典(decisions_journal.md該当Q番号/RULEエントリ)が実際に対応するか —
  `mandate/judgment_model.md`と`mandate/decisions_journal.md`を突合。
  (b) `mandate/judgment_model.md`が160行以内か — `wc -l mandate/judgment_model.md`(現在149行)。
  (c) CoDD例外(Wave境界殿必須)の非緩和が`judgment_model.md`・本ファイル双方に明記されているか。
  承認後はjudgment_model.md冒頭の未承認バナー(本エントリID参照)を削除すること |
  状態: approved(2026-08-05・承認者: 殿)
  備考: 2026-08-04 殿の明示許可により明日の裁定へ持ち越し(原文: 「AQ-001および未push分のキュー消化は明日の裁定に持ち越すことを明示的に許可する」)
  2026-08-05 殿裁定により承認、持ち越し状態は解消(出典: queue/shogun_to_karo.yaml cmd_147)

- ID: AQ-002 | 日付: 2026-08-05 | 操作内容: 未push commit群(69件、push直前に
  `git log origin/main..HEAD --oneline | wc -l`再実測、2026-08-05)のリモート(origin
  https://github.com/shun2580/multi-agent-shogun.git)へのpush |
  理由: 陣仕舞いに伴い、pushは「戻せない操作」としてapproval_queue経由の承認待ちとする(cmd_145 Part3の運用に従う) |
  doubt: (a) 対象ブランチ: `main`(`git branch --show-current`実測)。
  (b) commit範囲(push直前再実測): 最古`3341e34`(feat(instrumentation): Phase3 fired-state logging and
  fast-lane eligibility)〜最新`9db129f`(docs(cmd_149 subtask_149b): codify approval-material staleness
  pattern (E/F))。69件全件は`git log origin/main..HEAD --oneline --reverse`で再現可能。
  本サブタスク(subtask_149b)自身が作ったcommit(cmd_149フェーズ2最終工程分)を含む。
  (c) 公開されて困る内容の有無: `git log origin/main..HEAD -p`をAPI鍵/token/password/秘密鍵等の
  パターンで実走査した結果、実際の秘匿値のヒットは無かった(「secrets」という語自体は
  `projects/`がgit-ignoreされている旨の説明コメントとしてのみ出現)。ただし1件、要判断事項を発見した:
  `config/settings.yaml`(このunpushed範囲で新規追加されたファイル、origin/mainには未存在)に
  `ntfy_topic:`が平文で記載されていた(値はcmd_149で2026-08-05にローテーション済み・死値化のため
  本文からは削除。旧値はローカルcommit`6595b21`以前の履歴にのみ残存、履歴書き換えは行わない設計)。
  originリポジトリ
  (`shun2580/multi-agent-shogun`)は`gh repo view`実測で**PUBLIC**であることを確認した。
  ntfy.shはトピック名を知る者なら誰でも購読・投稿できる疑似秘匿値であるため、push後は
  このトピック名が公開され、第三者による通知の窃視・偽メッセージ投稿(なりすまし)のリスクが
  生じ得る。捏造で「問題なし」とせず、殿の判断(ローテーション後にpush/リポジトリ非公開化/
  許容してそのままpush、等)を仰ぐ。
  (d) 生成物(AGENTS.md/.github/copilot-instructions.md/agents/default/system.md)は
  `bash scripts/build_instructions.sh`再実行後の`git status --porcelain`差分ゼロで
  手書き元(CLAUDE.md等)との同期を確認済み(本サブタスクの陣仕舞いcommit時点) |
  状態: approved(2026-08-05・承認者: 殿・条件つき — ntfyトピックローテーション完了・
  config/settings.yaml追跡除外・残存ゼロ確認後にpushする条件、出典: cmd_149)
  備考: 2026-08-04 殿の明示許可により明日の裁定へ持ち越し(原文: 「AQ-001および未push分のキュー消化は明日の裁定に持ち越すことを明示的に許可する」)
  2026-08-05 殿裁定(cmd_149)により条件つき承認、doubt(b)をpush直前に再実測のうえpush実行(出典: queue/shogun_to_karo.yaml cmd_149)

- ID: AQ-003 | 日付: 2026-08-05 | 操作内容: 未push commit群(push直前に
  `git fetch origin main`実行後`git log origin/main..HEAD --oneline | wc -l`で
  再実測、2026-08-05)のリモート(origin https://github.com/shun2580/multi-agent-shogun.git)
  へのpush |
  理由: 本日cmd_150(フリーズ解除)〜cmd_154(陣仕舞い)の陣仕舞いに伴い、
  pushは「戻せない操作」としてapproval_queue経由の承認待ちとする(cmd_145 Part3の運用に従う。
  本則の「起票直前の再実測」則(cmd_149議題E)の初適用) |
  doubt: (a) 対象ブランチ: `main`(`git branch --show-current`実測)。
  (b) commit範囲(push直前・`git fetch origin main`実行後にsubtask_154cで再実測): 9件。
  最古`d48d152`(docs(cmd_150 subtask_150): codify ntfy rotation procedure + journal A/B/C
  entries)〜最新`006317d`(fix(cmd_154 redo subtask_154_redo): correct AQ-003 doubt(b) commit
  breakdown)。9件全件は`git log origin/main..HEAD --oneline --reverse`で再現可能。
  内訳: cmd_150(2件: d48d152, 303dd01)・cmd_151(1件: b88230a)・cmd_152(1件: f232eaf)・
  cmd_153(3件: ab192a2, 62973f8, 38d56db)・cmd_154(2件: 2ca8d2f, 006317d)。
  合計検算: 2+1+1+3+2=9件、総数9件と一致(subtask_154cにて自ら再実測・検算済み)。
  (c) 秘匿値混入の実走査結果: subtask_154bにて家老が独立に実走査済み(API鍵/token/
  password/秘密鍵パターン: 0件。ntfyトピック名プレフィックス`shogun_notify_`の
  ヒット1件は`mandate/verifiers.md`のcmd_150手順書内の命名規約の説明用テンプレート例
  〈実際のランダム値は含まない〉であり実害なしと判定済み)。
  `config/settings.yaml`は引き続きgit追跡外であることを確認済み(subtask_154b時点)。
  (d) 公開リポジトリ(`shun2580/multi-agent-shogun`、AQ-002時点でPUBLIC確認済み・
  本サブタスクでの再確認は未実施)への影響範囲: 本9件はいずれもmandate層の記帳・
  journal追記・スクリプト是正・approval_queue更新であり、新規の秘匿設定ファイル追加は
  無い(AQ-002の`config/settings.yaml`初回追加のような事象はこの範囲に含まれない) |
  状態: approved(2026-08-05・承認者: 殿・条件つき=家老の秘匿値走査ゼロ確認、出典:
  queue/shogun_to_karo.yaml cmd_154。家老の独立走査結果はsubtask_154bで確認済み)
  備考: subtask_154cにてpush直前再実測(7件→9件に増加、cmd_154分2件が追加)・検算のうえ
  approvedへ更新し、push実行に至った。

- ID: AQ-004 | 日付: 2026-08-08 | 操作内容: 新原則「記述の強制力は実装の実態を超えて謳わない
  (fail-loudの逆を文書上つくらない)」のjudgment_model.mdへの追加承認申請 |
  理由: 週次蒸留(cmd_155-D、初回実行)にてdecisions_journal.md 2026-08-05 RULEエントリ
  「cmd_144議題1: restart_watchers.sh建造可否」から抽出。殿本人の発言(原文ママ)「実際より
  強い強制力を謳う記述はfail-loudの逆」が根拠。実例: `.claude/settings.json`のkill系denyは
  Bashツール最上位コマンド文字列への前方一致のみで、スクリプト内部で呼ばれるkillは検査対象外
  であるにもかかわらず、当時のCLAUDE.md D006記述は実態より強い保証を謳っていた(是正済み:
  本リポジトリCLAUDE.md冒頭近く「Note on D006 enforcement scope」節)。原則5「サイレントな
  変更よりfail-loudを優先する」はコード側の挙動(拒否+理由提示の有無)を扱うが、本件は
  文書・記述側が実際の防御力を過大に謳うことの害を指摘しており対象が異なる(原則5=コードの
  沈黙、本件=文書の誇張) |
  doubt: (a) 原則5への出典追加(統合型)で足りるか、独立した新原則として立てるべきか——
  コード挙動と文書記述という対象の違いをどれだけ重視するかで判断が分かれる。
  (b) 本件は現時点で単一事例(cmd_144議題1)のみであり、他事例での再現は未確認。
  weekly_distill.mdが警告する「偽陽性の原則化(実運用で実証されていない仮説)」リスクに
  該当しないか、追加事例の蓄積を待つべきか、殿の判断を仰ぐ |
  状態: 条件付きpending据置(据置日: 2026-08-08・裁定者: 殿)
  備考: **再提出条件**: 「文書の強制力誇張」の2例目が観測された時点で、本件
  (AQ-004・cmd_144議題1由来)を1例目として引いて新設起案を再提出する。原則5への
  出典追加は行わない(対象が異なるため)。
  🔴**弱い設計の自覚(殿追加御指示・2026-08-08)**: 本設計(能動的な2例目検知を伴わない
  条件付き据置)は**能動照合機構を持たぬ弱い設計である**——2例目が観測されたかどうかは
  次に読む者の気づきに依存し、本据置自体には能動的な照合・検知の仕組みは無い。
  **機構化(2例目を能動的に検知する仕組みの新設)の起票条件は「2例目を見逃した事実が
  観測された場合」**であり、それ以前の機構の先回り建造(検知スクリプト・照合バッチ・
  リマインダの類)は禁ずる(原則14〔出典Q18〕の運用=観測が先・機構は事実の後)。
  判断理由の記帳: `mandate/decisions_journal.md`(2026-08-08付RULEエントリ)を参照。

  【追記・2026-08-09・subtask_161_D(足軽4号・Fable裁定Q22によるPREVENT記帳種別の
  新設・再提出条件の追加)】
  PREVENT型記帳3件の蓄積をもって、実害2例目の観測を待たず本件(AQ-004)の
  再提出条件充足と見なす(Fable裁定Q22、2026-08-09)。2026-08-08時点で
  PREVENT 1件目(cmd_159先回り記載)を記帳済み(出典: `mandate/decisions_journal.md`
  2026-08-08付PREVENTエントリ「cmd_159受け入れ条件への先回り記載」)。
  本追記は上記の既存doubt・備考(再提出条件・弱い設計の自覚)を変更するものでは
  なく、新設された代替充足条件(PREVENT 3件蓄積)を追加するのみである。

  【追記・2026-08-09・subtask_162_B(足軽4号・cmd_162陣仕舞い持ち越し3件記帳)】
  cmd_162陣仕舞い時点での持ち越し確認: 条件付き据置を維持する。再開トリガーは
  (1)実害2例目の観測、または(2)PREVENT 3件の蓄積(Fable裁定Q22)のいずれか。
  PREVENT件数を`grep -c "| PREVENT |" mandate/decisions_journal.md`で実測した
  結果、現在1件(2026-08-08付、cmd_159受け入れ条件への先回り記載、
  subtask_161_Dで記帳済みの1件目)のみであり、上記(2)の閾値(3件)には未達。
  よってcmd_162時点でも(1)(2)いずれの再開トリガーも未成立であり、据置を継続する。

  【追記・2026-08-26・subtask_180_D(足軽3号・cmd_180陣仕舞い・pending持ち越し記帳)】
  cmd_180陣仕舞い時点での持ち越し確認: 条件付き据置(再開トリガー未充足・PREVENT1件/3件)を
  維持する。将軍が本夜(2026-08-26)殿へ諮ったが、殿は陣仕舞いの御下知をもって応じられ、
  裁可は下っていない。次回へ持ち越す。既存doubt・備考・再開トリガー(実害2例目の観測、
  またはPREVENT3件の蓄積)はいずれも無変更。

- ID: AQ-005 | 日付: 2026-08-08 | 操作内容: 未push commit群(3件、提示直前に
  `git fetch origin main`実行後`git log origin/main..HEAD --oneline | wc -l`で
  再実測、2026-08-08)のリモート(origin https://github.com/shun2580/multi-agent-shogun.git)
  へのpush |
  理由: cmd_157の陣仕舞いに伴い、pushは「戻せない操作」としてapproval_queue経由の
  承認待ちとする(cmd_145 Part3の運用に従う) |
  doubt: (a) 対象ブランチ: `main`(`git branch --show-current`実測)。
  (b) commit範囲(提示直前・`git fetch origin main`実行後に再実測、2026-08-08): 3件。
  最古`3bf2dbd`(chore(cmd_157 subtask_157_A2): regenerate instructions from updated
  source templates)〜最新`ab3a72d`(fix(cmd_156 subtask_156_B): stop --phase-breakdown
  from showing unmeasurable timing as 0.0s)。内訳: cmd_156(1件: ab3a72d)・
  cmd_157(2件: 3bf2dbd, 1d94b07)。合計検算: 1+2=3件、総数3件と一致(足軽3号が
  subtask_157_C着手時点で自ら再実測・検算済み)。3件全件は
  `git log origin/main..HEAD --oneline --reverse`で再現可能。本サブタスク
  (subtask_157_C)自身が積むcommit、および並行実施中のsubtask_157_Bのcommitは
  この実測後に発生するため件数に含まれない(pending中に増加し得る)。
  (c) 公開されて困る内容の有無: 本エントリ起票時点では未走査。AQ-002/AQ-003に倣い、
  push承認確定・実行の直前に改めて再実測のうえ走査する運用とする(本3件はmandate層の
  記帳・instructions再生成・スクリプト是正のみで、新規の秘匿設定ファイル追加は無い) |
  状態: approved(2026-08-09・承認者: 殿・Fable裁定Q29経由・出典:
  `queue/shogun_to_karo.yaml` cmd_163 ruling_source「Fable裁定Q29
  (2026-08-09)・殿経由で受領。出典: ~/fable_situation_20260809_2130.md
  への回答」。承認条件=cmd_163 acceptance_criteria全項。条件充足の
  再確認結果はsubtask_163_A(本エントリ末尾の追記【subtask_163_A】節)
  参照)
  備考: 殿の明示許可により2026-08-09(明日)のキュー消化まで持ち越し(原文:
  「未push分はapproval_queueへ積み、pendingのまま明日へ持ち越すことを明示的に許可する。
  明日のキュー消化で判断する。」出典: queue/shogun_to_karo.yaml cmd_157)。

  【参考記録・01:53:40 push事件(確定事実・C-3)】2026-08-08 01:53:40、
  `origin/main`が`bb07740`→`f8b31bc`へpushされ、cmd_155(5件)・cmd_156(2件)の
  agent commit計7件(押し出したcommit`f8b31bc`自身を含む範囲`bb07740..f8b31bc`は
  合計8commit)が、approval_queueの承認を経ずに公開された。押し出したcommitは
  `f8b31bc`(docs: my_setup.mdに現在の環境状態のスナップショットを追記
  （2026-08-05時点）、01:53:31 commit)である。**実行者は殿ご自身であることを
  殿ご自身が明示確認された(2026-08-08)。これは推定ではなく確定事実として記録する**
  (将軍が`.git/logs/refs/remotes/origin/main`で当初検出した事実に、殿ご自身の
  確認が加わったもの)。**副作用(agent commit 7件が承認キューを経ずに公開されたこと)
  についても、殿の裁定により「押した本人が承認者ゆえ問題なし」とされており、
  規律違反(無断push等)として扱わない。** 本エントリ(c)の未走査は上記7件の
  内容とは無関係(それらは別途cmd_157【C.追加御下命】により家老が
  `bb07740..f8b31bc`を実走査し`queue/reports/karo_report.yaml`へ記録する)。
  なお本エントリのcommit範囲が3件と小さいのは、この直接pushにより従来の
  未push分の大半が既に反映されたためである。
  実在確認(足軽3号 subtask_157_C・2026-08-08実施): `.git/logs/refs/remotes/origin/main`
  に該当update行(`bb07740b65254a9ec069750777020448527ce9ed f8b31bcddc1adaf1af9a1d8ca0d326d9d4a85c66`、
  UNIXタイムスタンプ`1786121620`=`date -d @1786121620`で2026-08-08 01:53:40 +0900と
  一致確認)を確認。`git log bb07740..f8b31bc --oneline --reverse`で該当8commit
  (fb48171, ad5abcf, 35e10b1, c502b10, eed78fe, c8a28af, 4ea9408, f8b31bc)を
  確認済み。

  【追記・2026-08-08 22:xx・subtask_158_B2(足軽5号・cmd_158緊急封じ込め対応)】
  起票時点(3件)からcmd_158関連commitが積み増され、commit範囲が変化した。
  再実測(`git log origin/main..HEAD --oneline`、本追記直前実行): 現在8件。
  最古`3bf2dbd`(chore(cmd_157 subtask_157_A2))〜最新`1f4b612`
  (fix(config): untrack settings.yaml again (secret exposure incident,
  cmd_158))。内訳: 上記(b)記載の3件(cmd_156×1・cmd_157×2)に加え、
  cmd_157系1件(`ce337af` docs: file AQ-005 ...)・cmd_158系4件
  (`db0414f`, `1963907`, `c1b4227`, `1f4b612`)が追加。合計検算:
  3+1+4=8件、`git rev-list --count origin/main..HEAD`実測値8と一致。

  🔴**秘匿値混入の発覚と封じ込め**: 上記8件のうち`1963907`
  (feat(config): add fleet_idle_notify flags for cmd_158)が、cmd_149で
  git追跡から恒久除外されていたはずの`config/settings.yaml`
  (ntfy_topic秘匿値を含む)を「new file」として135行まるごと再追跡し、
  秘匿値を平文でcommit treeオブジェクトへ焼き込んだ事実が軍師QC
  (`gunshi_qc_158_B`)により発覚した。本サブタスク(subtask_158_B2)により
  `git rm --cached config/settings.yaml`を実行し追跡を再度解除した
  (commit `1f4b612`。working tree内容は無傷、index上の除外のみ)。

  🔴**状態の明示的更新(push可否)**: 上記(備考)の「殿の明示許可により
  明日へ持ち越し」は明日のキュー消化自体の許可であり維持されるが、
  **push実行自体は本項の追加条件を満たすまで実行不可**とする——
  `1963907`のblobオブジェクト自体に残る秘匿値の平文が除去される
  (履歴書換え、backup branch必須)まで、本AQ-005のpushは実行しては
  ならない。`1f4b612`による追跡解除は今後の変更を防ぐのみで、
  `1963907`のblob自体に焼き込まれた平文は消えていない点に注意。

  `1963907`のblobからの秘匿値除去(履歴書換え)は本サブタスクの範囲外
  であり、家老が別途(subtask_158_Aの完了によりworking treeが競合しない
  タイミングで)対応する。

  原因調査(本サブタスクで実施): ashigaru6の報告
  (`queue/reports/ashigaru6_report.yaml task_id: subtask_158_B`)には
  実行した具体的なgitコマンドの記載が無く、`git add -f`等の使用有無は
  報告からは特定不能だった。instructions/ashigaru.md・scripts/*.sh・
  lib/*.shを走査した結果、ashigaru向けのcommit手順やスクリプトに
  `git add -f`/`git add -A`/`git commit -a`等の無差別追加パターンを
  常用させる記述・実装は見つからなかった(README.md:913の
  `privategit add -f`は別のbare repo(私用ファイル専用)向けの
  file-scoped指定であり本件とは無関係)。本件は構造的リスクではなく
  ashigaru6号個別の一回性ミスと判断する(是正提案はしない・発見のみ)。

  【追記・2026-08-08 22:xx・subtask_158_G(足軽1号・cmd_158-G履歴書換え仕上げ)】
  🔴**1963907のblob除去(履歴書換え)完了**: `git rebase --onto 1963907^ 1963907
  main`を実行(backup branch: `backup-cmd158-pre-history-purge-20260808-222447`、
  削除せず保持)。`1f4b612`(untrack commit)は"patch contents already upstream"で
  自動スキップされ`Successfully rebased`まで正常完了(想定内パターン)。
  検証結果: `git log --oneline | grep 1963907`は空(mainから消滅を確認)、working
  tree上の`config/settings.yaml`は実行前バックアップ(`/tmp/cmd158_settings_yaml_backup_*`、
  検証後削除済み)と`diff`差分ゼロで内容無傷、`fleet_idle_notify_enabled`・
  `fleet_idle_notify_stable_sec`の2行含め健全、`git ls-files config/settings.yaml`は
  空(追跡外)。退避していた本ファイル(approval_queue.md)・queue/tasks/gunshi.yaml
  の変更は`git stash pop`で復元し内容一致確認済み。以上により、AQ-005本文
  (状態:pending)が課していた「1963907のblobから秘匿値が除去されるまでpush不可」
  という追加条件(217-223行目)は**解消**した。ただし**AQ-005本来のpush承認自体は
  従来どおり明日(2026-08-09)のキュー消化(殿の判断)を待つ**——本追記は
  自動承認を意味しない。

  🔴🔴**新規発見・別インシデント(本サブタスクのスコープ外・要緊急判断)**:
  Step4検証中、`git log --all --oneline -- config/settings.yaml`が空にならず、
  `1963907`/`1f4b612`(backup branch由来)に加えて、**現mainの祖先として
  `dda6b30`(cmd_113)〜`60a0299`(cmd_149「chore(config): rotate ntfy_topic,
  untrack settings.yaml, add .example」)までの11件のcommitがconfig/settings.yamlを
  追跡していた**ことが判明した(`git merge-base --is-ancestor 60a0299 HEAD`
  =true・`dda6b30`も同様=true、いずれもbackup branchではなくmain本流の祖先)。
  さらに`git merge-base --is-ancestor 60a0299 origin/main`
  =true・`dda6b30`も同様=trueであり、**この範囲は既にorigin
  (https://github.com/shun2580/multi-agent-shogun.git)へpush済み**である
  ことを確認した。cmd_149のcommit message自体が「rotate ntfy_topic」と
  明記しており当時秘匿値のローテーションが実施された形跡はあるが、
  dda6b30〜60a0299の各commit blobにどの時点の値が焼き込まれているか
  (ローテーション済みで無効化された値のみか、複数世代混在か)は本サブタスクの
  権限・スコープ外につき調査していない(秘匿値そのものへの接触を避けるため)。
  この件は1963907除去とは別次元・別スコープの既存インシデントであり、
  本サブタスクでは一切手を加えていない(触れていない)。家老への緊急報告
  (inbox_write urgent)で別途エスカレーション済み。**この新規発見について
  家老/殿が評価・判断するまで、AQ-005のpush実行は本件を理由に不可と
  みなすべきである**(1963907分の条件解消とは独立した、新たなpushブロッカー)。

  【追記・2026-08-08 22:5x・subtask_158_H(足軽1号・dda6b30〜60a0299の独立再現検証
  +一次資料照合)】上記(subtask_158_G記載分)を貴殿(足軽1号)自身が独立に再現検証し、
  加えて家老修正指示(msg_20260808_223557)に従い、論点を①②③の3点に分けて記載する。

  ①**1963907除去(履歴書換え)**: subtask_158_Gにて完了済み(上記参照)。本件は解決済み。

  ②**dda6b30〜60a0299(cmd_113〜cmd_149)の公開済み旧履歴に含まれるntfy_topic値
  そのものの安全性**: 家老の先行調査(1)(2)(3)を貴殿が独立に再現し、技術的に完全
  一致した。`git log -1`でdda6b30=cmd_113(2026-07-27)・60a0299=cmd_149「rotate
  ntfy_topic, untrack settings.yaml」(2026-08-05)と確認。`git log --all --oneline
  -- config/settings.yaml`でdda6b30〜60a0299間の11件を確認、両commitとも
  `git merge-base --is-ancestor`でHEAD・origin/main双方の祖先(=既にGitHub公開済み)
  であることも確認した。🔴値そのものは非開示・ハッシュのみで比較:
  `git show 60a0299^:config/settings.yaml | grep '^ntfy_topic:' | sha256sum`
  (ローテーション前)と`grep '^ntfy_topic:' config/settings.yaml | sha256sum`
  (現在)は**不一致**——ローテーション前後で値が異なることを独立に確認した。
  したがって**値そのものとしては既に無効化(死値化)されており、この範囲の
  既公開履歴は「値の漏洩」という観点では新規のpushブロッカーとして扱わない**。
  🔴既に公開済みの履歴を書き換える(force-push相当の履歴改変)ことは、
  本件では推奨しない。理由: (a)値自体は既にローテーション済みで無効化されており
  「値としての」実害が無い(b)公開済み履歴の書換えはfork・clone・キャッシュ等に
  旧版が残存する可能性があり完全な除去を保証できない(c)force-push相当の操作は
  D003の趣旨に照らし極めて慎重を要する操作であり、下記③が未解決のまま実施すべき
  ではない。

  ③🔴🔴**(②とは別軸・未解決)旧ntfyトピックの購読解除(⑤)の実施記録が
  見つからない**: `mandate/decisions_journal.md:112`(CORRECTエントリ、将軍の
  自己申告)・`mandate/verifiers.md:132-163`(ntfyトピックローテーション完全手順・
  cmd_150で成文化)を確認したところ、正しい手順は①新名生成→②git外伝達→
  ③購読替え→④到達確認→**⑤旧購読解除(必須)**→⑥pushの順であり、「⑤購読解除
  して初めて、旧トピック名は死値となる」と明記されている。しかしcmd_149の実施には
  この⑤が欠けていたことが将軍自身の自己申告で確定しており(decisions_journal.md:112)、
  ⑤が事後的に実施されたことを示す記録は`mandate/decisions_journal.md`・
  `mandate/approval_queue.md`(本ファイル)・`dashboard.md`・`memory/MEMORY.md`の
  いずれにも見つからなかった(貴殿が`grep -rn '旧購読\|旧トピック\|購読解除'
  mandate/ dashboard.md`で独立に再確認済み。ヒットはverifiers.mdの手順定義文と
  decisions_journal.mdのCORRECTエントリ自体のみ)。
  この事実は`queue/reports/gunshi_report.yaml task_id: gunshi_qc_158_G`
  (2026-08-08T22:40:00完了、north_star_alignment.status: misaligned、urgent: true)
  でも独立に指摘されている。**②が示す「値としての無害化」は、旧トピック名という
  『器』そのものが今も公開GitHub履歴に生きたまま存在し、殿がその購読を実際に
  解除していなければ第三者が偽の通知を投げ込み殿を欺きうる、という別種のリスクを
  解消しない**。この確認・解決は殿ご本人がntfyアプリ側の購読設定を確認する以外に
  方法が無く、いかなるエージェントもgit操作の範囲では確認・解決できない
  (D001-D008の範囲外)。

  **結論**: ①②は解決済み(②は「値としてのpushブロッカー」ではなくなった)。
  ③は未解決・別軸の要対応事項であり、殿ご本人の確認が必要。家老は既にdashboard.md
  🚨要対応セクションへの記載・ntfy緊急送信(22:35送信済み、gunshi_qc_158_G発)で
  殿への到達を確保済み。AQ-005本来のpush承認自体は、②③いずれについても
  従来どおり家老/殿の総合判断(2026-08-09キュー消化)を待つものとし、本追記は
  自動承認を意味しない。

  【追記・2026-08-08 22:5x・subtask_158_I(足軽1号・cmd_159殿裁定(3)(4)の記帳)】

  🔴**(3) subtask_158_Gの事後承認(1963907のblob除去、cmd_159殿裁定(3))**:
  subtask_158_G(上記【追記・2026-08-08 22:xx・subtask_158_G】参照、1963907の
  blob除去・backup branch: `backup-cmd158-pre-history-purge-20260808-222447`)は
  殿により事後承認された(2026-08-08、出典: `queue/shogun_to_karo.yaml` cmd_159
  command(3)節「(3)subtask_158_G(1963907のblob除去): **事後承認する**。backup
  branch保持により可逆性が担保されていた以上『戻せる操作=自動進行』の運用に
  整合する。」)。承認理由: backup branch保持により可逆性が担保されていたため、
  「戻せる操作=自動進行」の運用(`instructions/karo.md`「戻せる/戻せない操作の
  分岐」節)に整合すると殿が判断された。
  🔴**backup branch自体の削除は「戻せない操作」であり、今は削除しないこと**。
  AQ-005のpush完了・安定確認後に、改めてapproval_queue経由で(新規AQエントリと
  して)諮ること(出典: 同cmd_159 command(3)節「ただし backup branch の削除は
  戻せない操作ゆえ、AQ-005 push完了・安定確認後に approval_queue 経由で
  諮れ(今は消すな)。」)。

  🔴**(4) push直前再走査の必須条件(cmd_159殿裁定(4))**: AQ-005のpush実行前の
  再走査は、`subtask_158_B`(秘匿値混入発覚)・`subtask_158_G`(blob除去)・
  `subtask_158_H`(公開履歴の無害化2点セット確認)の結論をすべて反映した状態で
  行うことを必須条件とする(出典: `queue/shogun_to_karo.yaml` cmd_159
  command(4)節「(4)AQ-005(push): 明日の消化予定を維持。🔴push直前の再走査は
  158_B/G/H の結論をすべて反映した状態で行うことを必須条件とする。」)。
  明日(2026-08-09)のキュー消化予定自体は維持される。

  【追記・2026-08-09・subtask_162_B(足軽4号・cmd_162陣仕舞い持ち越し3件記帳)】
  cmd_162陣仕舞い時点で、AQ-005のpush承認について**殿の明示確認は未取得のまま
  持ち越す**(出典: `queue/shogun_to_karo.yaml` cmd_162 acceptance_criteria
  「🔴AQ-005(push)には一切手を触れないこと。pushを実行するな。殿の明示確認が
  未取得のまま持ち越す旨をエントリと報告の双方へ明記すること」)。
  再開トリガー=殿の承認。承認後のpush実行前には、cmd_159殿裁定(4)
  (本エントリ上記【追記・subtask_158_I】節参照)のとおり158_B/G/Hの結論を
  すべて反映した状態での再走査が必須条件であることを、cmd_162陣仕舞い記録として
  改めて明記する。本追記は追記専用であり、状態欄(pending)・既存本文はいずれも
  変更していない。

  【追記・2026-08-09・subtask_163_A(足軽2号・cmd_163 push前検証・push未実行)】
  殿裁定(Fable Q29経由・2026-08-09、出典: `queue/shogun_to_karo.yaml`
  cmd_163)によりAQ-005のpush自体は承認された。本サブタスクはその承認条件
  (cmd_163 acceptance_criteria)の充足を**今この時点で**再確認したのみで、
  `git push`は実行していない(push実行は後続subtask_163_Bの担当)。

  🔴**(1) 未pushコミット再実測**: `git fetch origin main`実行後
  `git log origin/main..HEAD --oneline | wc -l` = 22件(将軍21:30時点値・
  cmd_159時点8件・起票時3件、いずれも援用せず自ら再実測)。内訳
  (`git log origin/main..HEAD --oneline | grep -oE '\(cmd_[0-9]+' | sort |
  uniq -c`): cmd_158×6・cmd_161×5・cmd_157×4・cmd_160×3・cmd_159×2・
  cmd_162×1・cmd_156×1。合計検算: 6+5+4+3+2+1+1=22件、総数22件と一致。

  🔴**(2) 秘匿値の全件走査**: `git log origin/main..HEAD -p`を
  `(api[_-]?key|secret|token|password|private[_-]?key|-----BEGIN)`
  (大小文字区別なし)で走査、5件ヒット。全件を実内容確認した結果、いずれも
  秘匿値インシデントの説明文(decisions_journal記述・approval_queue追記)、
  または秘匿値検知機構(`fleet_idle_notify`のsecret-leak guard)の実装コード
  中の"secret"という単語であり、実際の鍵・token・password値は含まれない
  ことを確認。追加で`ntfy_topic`(config/settings.yaml.example実キー名)を
  対象に走査(10件ヒット)したが、全件が①のRULEエントリ本文中の説明文、
  または②ハッシュ比較コマンド文字列(`git show 60a0299^:config/settings.yaml
  | grep '^ntfy_topic:' | sha256sum`)であり、`ntfy.sh/<topic>`形式のURLは
  0件だった。ただし`grep -inE '^\+.*ntfy_topic\s*:'`は2件ヒット。いずれも
  `mandate/decisions_journal.md`追記行中の上記ハッシュ比較コマンド引用文字列
  であり、`+ntfy_topic: <実値>`形式の実キー・実値の追加ではないことを
  目視確認した。**ゼロ確認**。

  🔴**(3) cmd_159殿裁定(4)の3点、いま現在の再確認**:
  (a) subtask_158_B(秘匿値混入): `git ls-files | grep -c
  'config/settings.yaml$'` = 0。現在もuntracked、確認OK。
  (b) subtask_158_G(blob除去、対象commit `1963907`): `git log --oneline |
  grep -c 1963907`(main/HEAD) = 0、`git log origin/main --oneline |
  grep -c 1963907` = 0——mainからの消滅を確認(subtask_158G原記録の解決
  基準と一致)。参考: `git log --all --oneline | grep -c 1963907` = 1だが、
  到達元はローカルbackup branch
  `backup-cmd158-pre-history-purge-20260808-222447`のみ(`git for-each-ref`
  で確認、origin側に同名refは存在しない)。同branchはcmd_159殿裁定(3)
  「backup branch保持により可逆性が担保されていた」ことを根拠に**意図的に
  削除せず保持**されているものであり、その残存は解決の未達ではなく承認済み
  設計どおりの状態。確認OK。
  (c) subtask_158_H(公開済み履歴の無害化2点セット): ①値ローテーション済み
  ——`git show 60a0299^:config/settings.yaml | grep '^ntfy_topic:' |
  sha256sum` = `9167041e...`(ローテーション前)、`grep '^ntfy_topic:'
  config/settings.yaml | sha256sum` = `6bf9a65b...`(現在値、settings.yamlは
  untrackedのためファイルシステムから直接読取)。両者不一致——値が異なる
  ことを再確認。②旧購読解除済み——`mandate/decisions_journal.md:130`
  (2026-08-08付CORRECTエントリ)に「殿ご自身がntfyアプリを実確認され
  『既に解除済み』と確定」と記帳済みであることを確認(再現手段を持たない
  ため、殿確認済み・journal記載済みであることの確認に留める)。

  **結論**: (1)(2)(3)いずれも再確認でき、cmd_163 acceptance_criteriaの
  push前提条件は全項充足。**push実行可能**(実際のpush・
  `AQ_APPROVED_ID=AQ-005`付与・`ALLOW`ログ確認は後続subtask_163_Bで実施)。
  詳細な実行コマンド・出力全文は`queue/reports/ashigaru2_report.yaml
  task_id: subtask_163_A`参照。

  【追記・2026-08-10・subtask_167_C2(足軽4号・cmd_167陣仕舞い・新規未push分の
  pending持ち越し記帳)】
  AQ-005本来のpush(commit `543666a`、subtask_163_B)完了後、cmd_164〜cmd_167の
  作業により新たな未push commit群が積み増された。cmd_167着手時点で自ら再実測
  (`git fetch origin main`実行後`git log origin/main..HEAD --oneline | wc -l`、
  2026-08-10): **11件**(内訳`git log origin/main..HEAD --oneline | grep -oE
  '\(cmd_[0-9]+' | sort | uniq -c`: cmd_164×3・cmd_165×4・cmd_166×3・cmd_167×1、
  合計検算3+4+3+1=11件、総数11件と一致)。cmd_167本文(acceptance_criteria)は
  「10件」と記すが将軍の直近実測は11件であり、いずれも援用せず本サブタスクで
  改めて再実測した結果も11件(将軍実測と一致)。
  🔴**殿の明示許可により、この新規未push分11件はpendingのまま持ち越し
  (cmd_167・2026-08-10)**(出典: `queue/shogun_to_karo.yaml` cmd_167
  acceptance_criteria「未push 10件とAQ-008は、殿の明示許可によりpendingのまま
  持ち越してよい」)。本追記はAQ-005本来のpush承認(既にapproved・push実行済み)を
  変更するものではなく、その後新たに積み増された別範囲のcommit群についての
  持ち越し記録である。pushは本サブタスクでも実行していない。

- ID: AQ-006 | 日付: 2026-08-08 | 操作内容: `config/settings.yaml`
  `features.fleet_idle_notify_enabled` を `off` → `enforce` へ恒久化するか
  (cmd_158最終工程・subtask_158_E) |
  理由: cmd_158は陣「全消化・下命待ち」遷移をntfyで殿へ通知する機構を
  建造する任務であり、コード実装(subtask_158_A/C)・軍師QC PASS・
  config/settings.yaml.exampleへの雛形追記(subtask_158_F)・
  instructions/karo.md reporting_mode表への類型追加(subtask_158_D)は
  全て完了済みだが、機構は既定`off`のため恒久化(常用化)の可否判断は
  instructions/karo.md「新規feature flagの常用化判断」(cmd_144議題5・
  cmd_147制定)に従いapproval_queue経由で殿に委ねる |
  doubt: 🔴**実機発火・抑止ログいずれも実測できていない(0件)**。
  理由は機能未実装ではなく、**現在稼働中のkaro担当inbox_watcher.sh
  プロセス(PID 2178、起動2026-08-08 21:22:33)が、fleet-idle機構実装
  commit(`1f9faf7` 22:08:48・`7336fcb` 22:34:40、いずれもプロセス起動後)
  より前の旧版スクリプトを読み込んだまま稼働し続けているため**。
  証拠: (1)`/proc/2178/fd/255`が`scripts/inbox_watcher.sh (deleted)`を
  指しており当該プロセスの実行コードは既にディレクトリから外れた旧
  inode由来と確認、(2)`/proc/2178/fd/255`の中身(2189行)を直接grepしても
  `check_fleet_idle_notify`・`build_fleet_idle_message`・`fleet_idle`の
  いずれの文字列も1件もヒットせず(現ディスク上のファイル2535行には
  両関数とも存在)、(3)実機で`fleet_idle_notify_enabled: enforce`へ
  一時変更・全10エージェント(shogun/karo/gunshi/ashigaru1-7)のinbox
  未読ゼロを維持した状態で40秒(karoのinotify timeout一巡分)待機したが、
  `logs/ntfy.log`(228行のまま増加なし)・`logs/fleet_idle_events.jsonl`
  (未生成)・`logs/.fleet_idle_candidate_since`(未生成)のいずれにも
  変化なし——静的証拠と一致する形で実測上も無反応だった(subtask_158_E
  実施記録・`queue/reports/ashigaru2_report.yaml`参照)。
  この状態でのenforce恒久化はプロセス再起動(inbox_watcher.sh再起動)を
  経て初めて実効化される。再起動はD006(kill/pkill禁止)によりいかなる
  エージェントも自身で実行できず、殿の手元操作を要する。
  **常用化(off→enforce)の可否そのものは殿の判断事項として本エントリに
  委ねるが、判断材料として「再起動未実施のため実測0件」という制約を
  上記のとおり明示する**。再起動後に改めて実測(発火ログ・抑止ログとも
  最低1件)を取得してから本エントリを最終承認する運用を推奨する。 |
  状態: approved(2026-08-09・根拠: 実発火実証済み・Fable裁定Q24)
  備考: 2026-08-09T00:37:35に実機発火を実証済み(出典: `logs/ntfy.log:235`
  該当行、cmd_158 caveat解除の根拠と同一)。Fable裁定Q24(実証優先の資格要件
  3条件——cmd_158の実発火が観測された時点で見送り理由は消滅)により、
  上記doubt欄が示していた「実測0件」の制約は解消され、この実証をもって
  承認条件が満たされたと判断する(出典: `~/fable_situation_20260809_0100.md`・
  Fable裁定2026-08-09・殿経由で受領)。🔴flagは既に`enforce`
  (`config/settings.yaml` `features.fleet_idle_notify_enabled: enforce`)
  であり**値の変更は不要**——本承認は現状維持(enforce据置)を承認内容とする
  ものであり、追加のflag変更操作は伴わない(subtask_160_C・足軽4号記帳)。

- ID: AQ-007 | 日付: 2026-08-09 | 操作内容: `config/settings.yaml`
  `features.git_push_block_enabled` を `off`(現状)→恒久的に`observe`または
  `enforce`へ移行するか(cmd_159最終工程・subtask_159_D) |
  理由: cmd_159はgit pushをPreToolUseで機械的にdenyし、
  `mandate/approval_queue.md`の承認済みAQエントリを`AQ_APPROVED_ID`環境変数で
  明示指定した場合のみ通す機構を建造する任務であり、コード実装
  (subtask_159_A)・settings.jsonへのフック登録(subtask_159_C)・
  flag新設(既定off、subtask_159_B)は軍師QC PASS済み。加えて本サブタスク
  (subtask_159_D)により**実機での挙動確認**(設定記述とテスト緑のみでなく、
  実際にPreToolUseがdenyすることの実測)まで完了した。恒久化(off→observe
  または off→enforce)の可否判断はinstructions/karo.md「新規feature flagの
  常用化判断」(cmd_144議題5・cmd_147制定)に従いapproval_queue経由で殿に
  委ねる |
  doubt: 🔴**実測結果(本サブタスクで取得、2026-08-09)**:
  (1) Step1(observeモード・合成JSON単体テスト、`logs/git_push_block.log`
  00:11:21〜00:11:38記録): (a)`AQ_APPROVED_ID`無しの`git push origin main`
  → `WOULD-DENY reason="no AQ_APPROVED_ID prefix found in command"`
  (b)存在しないAQ ID(AQ-999)指定 →
  `WOULD-DENY reason="AQ entry AQ-999 not found in approval_queue.md"`
  (c)承認済みAQ ID(AQ-001、状態: approved)指定 → `ALLOW`
  (d)`git status`(push非対象) → `ALLOW`。4パターンとも期待通りの判定。
  (2) Step2(enforceモード・実機push、二重安全策使用):
  ダミーリモート`cmd159_test_dummy`(`/nonexistent/path/that/does/not/exist`、
  実在しないローカルパス)を作成した上で、実際にBashツール経由で
  `git push cmd159_test_dummy main`(`AQ_APPROVED_ID`無し)を発行した結果、
  PreToolUseによって**実際にコマンドが実行されずdeny**された
  (エラー出力: `git push blocked (cmd_159): no AQ_APPROVED_ID prefix found
  in command`)。`logs/git_push_block.log`にも`[2026-08-09T00:12:02+09:00]
  DENY mode=enforce session=e070c0ae-6003-4221-994c-94343a811057 tool=Bash`
  として記録済み。実在するリモート(origin/upstream)への到達は一切無し
  (二重安全策: (i)hookが機能していれば到達前にdeny、(ii)仮にhook不発でも
  ダミーリモートは実在しないローカルパスにつき即座にローカルエラー終了、
  いずれも満たしダミーリモートは検証後に`git remote remove`で削除済み)。
  (3) Step3(flag復元): 検証後`git_push_block_enabled`を`off`へ復元し、
  `git diff config/settings.yaml`で差分ゼロ(コミット済み状態と一致)を
  確認。off復元後は`git_push_block.log`に新規行が追加されないこと
  (early returnによりpython起動自体が発生しないこと)も確認した。
  🔴**恒久化(常用化)移行閾値の暫定案**(cmd_158のAQ-006と同型の4条件
  フォーマットに倣う。最終値は将軍・殿の裁定に委ねる):
  (1) AQ承認済みpush通過1回以上 — 本サブタスクのStep1(c)で1回確認済み。
  (2) 非承認push試行のWOULD-BLOCK検出1回以上 — 本サブタスクのStep1(a)(b)・
  Step2で複数回確認済み。
  (3) 偽WOULD-BLOCKゼロ — 本サブタスクの範囲では偽陽性(非push系コマンドが
  誤ってWOULD-DENY/DENYされた事例)は観測されなかった(Step1(d)・
  ダミーリモート削除後の`tail`コマンド等、`push`という文字列自体を含む
  非git-push系コマンドはいずれも正しく`ALLOW`)。
  (4) fail-open発生ゼロまたは全件原因説明済み — 本サブタスクでは
  `FAIL-OPEN`ログの発生は無かった(`grep -c FAIL-OPEN logs/git_push_block.log`
  で確認可能)。
  件数閾値は「対象評価5件以上」を暫定案として示すが、本サブタスクで得られた
  評価件数は単一セッション内の合成テスト+実機テスト計6件(Step1×4+Step2×1
  +off復元後確認×1)にとどまり、AQ-006が指摘したような「複数セッション・
  複数エージェントに跨る実測」は未実施である点に留意されたい。最終的な
  移行閾値・件数条件は将軍・殿の裁定に委ねる |
  状態: approved(承認者: 殿・Fable裁定〈2026-08-26 ~/fable_ruling_20260826_q38q41.md
  項目9〉経由・2026-08-26)。承認根拠: 「push互換はcmd_163のAQ_APPROVED_ID経路で
  実証済み」を、cmd_171 subtask_171_A(足軽1号)が`logs/git_push_block.log`を
  実読して確認した(65行目 `[2026-08-09T21:59:33+09:00] ALLOW mode=observe
  session=d9735ace-e152-4881-92b9-84d9b4b3e0da tool=Bash` — AQ-005 push
  〈commit 543666a〉に対応するsession IDと一致、DENY/WOULD-DENYではなくALLOW)。
  `config/settings.yaml` `features.git_push_block_enabled`を`observe`→
  `enforce`へ変更済み(2026-08-26)
  備考: 【追記・2026-08-09・subtask_160_C(足軽4号・Fable裁定Q24によるobserve
  移行)】Fable裁定Q24(cmd_158実発火観測をもって実証優先の見送り理由は消滅)
  に基づき、`config/settings.yaml` `features.git_push_block_enabled`を
  `off`→`observe`へ変更した(working tree限定・git追跡対象外ファイルにつき
  commit不要)。変更後、合成JSONペイロード経由(subtask_159_D検証手法に倣う、
  実push試行はsubtask_159_Dで完了済みにつき重複させず)で3パターンを
  `logs/git_push_block.log`にて実機確認: (a)`AQ_APPROVED_ID`無しの
  `git push origin main` → `WOULD-DENY reason="no AQ_APPROVED_ID prefix
  found in command"`(session=subtask_160_C_test1、01:09:00)、
  (b)存在しないAQ ID(AQ-999)指定 → `WOULD-DENY reason="AQ entry AQ-999 not
  found in approval_queue.md"`(session=subtask_160_C_test2、01:09:00)、
  (c)承認済みAQ ID(AQ-006、本サブタスクにより本エントリ直前でapproved化
  済み)指定 → `ALLOW`(session=subtask_160_C_test3、01:09:00)。3パターンとも
  期待通りの判定(observeモードにつきいずれもdenyせず通過、WOULD-DENY/ALLOWの
  ログ記録のみ)。🔴副次的観測: 上記検証コマンド自体(echoペイロード文字列に
  `git push origin main`という文字列断片を含む)が、本物のPreToolUseフック
  (settings.json経由・observe化直後に有効化)により本足軽自身のBashツール
  呼出しとしても検知され、実セッションID(3fd216a0-...)でWOULD-DENYが1件
  ログされた(01:08:59、reason=AQ-999、これは本検証コマンド文字列内の最初の
  `AQ_APPROVED_ID=AQ-999`断片が拾われたもの)。これは「pushという文字列を
  含む合成テストコマンド自体がフックの対象になり得る」というスクリプト自身の
  設計上の限界(粗いフィルタ、コメント参照)の実例であり、観測を汚染する
  実害は無い(observeモードにつきdenyされず、テストコマンドは正常完了)。
  enforce昇格は本エントリ単独では行わず、AQ-005のpush実測後に改めて諮る
  (出典: `queue/shogun_to_karo.yaml` cmd_160 acceptance_criteria)。
  🔴AQ-005には一切触れていない(閲覧のみ、変更・push実行いずれも未実施)。

  【追記・2026-08-09・subtask_162_B(足軽4号・cmd_162陣仕舞い持ち越し3件記帳)】
  cmd_162陣仕舞い時点でもenforce昇格は引き続き保留する。再開トリガー=AQ-005の
  push実測後に「承認済み経路(`AQ_APPROVED_ID`指定)が実際に通る」ことを
  確認すること(出典: `queue/shogun_to_karo.yaml` cmd_162【持ち越し3件】節
  「AQ-007: git_push_blockのenforce昇格。再開トリガー=AQ-005 pushで
  『承認済み経路が実際に通る』実測を得ること。」既存の本文備考・subtask_160_C
  追記「enforce昇格は本エントリ単独では行わず、AQ-005のpush実測後に改めて
  諮る」と同一方針を、cmd_162陣仕舞い記録として再確認するもの)。

  【追記・2026-08-09・subtask_163_B(足軽2号・AQ-005実push実行・承認済み経路の実測回収)】
  AQ-005承認編集commit後、`AQ_APPROVED_ID=AQ-005`を明示付与して
  `git push origin main`を実行(commit `543666a`、fetch後の未push数23件→
  push後0件を確認)。`logs/git_push_block.log`最終行に本pushに対応する
  `ALLOW mode=observe session=d9735ace-e152-4881-92b9-84d9b4b3e0da tool=Bash`
  行を実出力で確認した(DENY/WOULD-DENYではなくALLOW)。これによりAQ-007の
  enforce昇格判断に必要としていた「承認済み経路(`AQ_APPROVED_ID`指定)が
  実際にobserveモードのpushを通る」実測を1件取得した。昇格の可否自体は
  本追記で判断せず、殿の判断へ委ねる(状態欄参照)。

  🔴STALE(自動再実測不一致・2026-08-09T22:55:23+0900・軍師/家老が要再確認): 記載値=1件、実測値=4件
  🔴訂正(cmd_165 subtask_165_D・2026-08-09T23:17:18+0900): 上記STALE標識は誤検知である。
  `scripts/check_approval_queue_staleness.sh`のキーワード限定ヒューリスティックが、
  未pushコミット数とは無関係な文脈の「1件」(出典: 本エントリ直前の
  subtask_163_B追記「これによりAQ-007のenforce昇格判断に必要としていた
  『承認済み経路(`AQ_APPROVED_ID`指定)が実際にobserveモードのpushを通る』
  実測を1件取得した」——ここでの「1件」はALLOW実測の取得件数であり、未pushコミット
  件数ではない)を誤って比較対象に拾ったもの。実際の不一致は存在しない。
  詳細: `queue/reports/gunshi_report.yaml task_id: gunshi_qc_165_A`。
- ID: AQ-008 | 日付: 2026-08-09 | 操作内容: backup branch
  `backup-cmd158-pre-history-purge-20260808-222447` の削除可否
  (cmd_163・subtask_163_B起票) |
  理由: cmd_159殿裁定(3)により、当該backup branchはblob除去(subtask_158_G)の
  可逆性担保として意図的に削除せず保持されてきたが、削除可否そのものの判断は
  「push安定確認後に改めて諮る」こととされていた(出典: `queue/shogun_to_karo.yaml`
  cmd_163 acceptance_criteria「backup branch削除は実行するな。push安定確認後に
  諮るための新規AQエントリ(AQ-008)を起票するのみ」)。AQ-005のpush実行
  (本cmd_163・subtask_163_B)により「push安定確認後」の前提条件が成立したため、
  本エントリを起票する |
  doubt: (a) push実行(本cmd_163・subtask_163_B)が安定完了したこと——
  commit `543666a`のpush後、`git log origin/main..HEAD --oneline | wc -l`が
  0件であることを確認済み、かつ`logs/git_push_block.log`に対応する`ALLOW`行を
  実出力で確認済み(詳細は本エントリ直前のAQ-007追記および
  `queue/reports/ashigaru2_report.yaml task_id: subtask_163_B`参照)。
  (b) subtask_163_A2で軍師が発見した事実——当該backup branchには
  `git log --all -p -- mandate/approval_queue.md`で検出可能な平文の旧
  ntfy_topic値が1件含まれる。当該コミットは`git log origin/main..HEAD`の
  範囲外(origin未到達のローカル専用ref経由)につき今回のpush対象には影響
  しなかったが、backup branch自体を残す限りこの平文値はローカルに残存し
  続ける。これはbackup branch削除の是非判断における新たな検討材料であり、
  削除する場合は「可逆性の担保」という保持理由と「平文の旧秘匿値の残存」
  という削除理由が対立する形になる点に留意されたい |
  状態: approved(2026-08-27・承認者: 殿)
  出典: 殿の直接裁定(2026-08-27・端末上の応答、将軍が3件を諮り3件とも承認。AQ-008は
  「削除する(ただしAQ-012次第)」——AQ-012送出完了により条件充足)
  🔴STALE(自動再実測不一致・2026-08-09T22:55:23+0900・軍師/家老が要再確認): 記載値=1件、実測値=4件
  🔴訂正(cmd_165 subtask_165_D・2026-08-09T23:17:18+0900): 上記STALE標識は誤検知である。
  `scripts/check_approval_queue_staleness.sh`のキーワード限定ヒューリスティックが、
  未pushコミット数とは無関係な文脈の「1件」(出典: doubt(b)の記述「当該backup branch
  には`git log --all -p -- mandate/approval_queue.md`で検出可能な平文の旧
  ntfy_topic値が1件含まれる」——ここでの「1件」は平文値の混入件数であり、未push
  コミット件数ではない)を誤って比較対象に拾ったもの。実際の不一致は存在しない。
  詳細: `queue/reports/gunshi_report.yaml task_id: gunshi_qc_165_A`。

  【追記・2026-08-10・subtask_167_C2(足軽4号・cmd_167陣仕舞い・pending持ち越し記帳)】
  cmd_167陣仕舞い時点で、AQ-008(backup branch削除可否)は引き続き**pendingのまま**
  持ち越す。🔴**殿の明示許可によりpendingのまま持ち越し(cmd_167・2026-08-10)**
  (出典: `queue/shogun_to_karo.yaml` cmd_167 acceptance_criteria「AQ-008は、殿の
  明示許可によりpendingのまま持ち越してよい」)。状態欄(pending)・既存本文は
  いずれも変更していない(追記専用)。

  【追記・2026-08-26・subtask_178_B(足軽2号・Q42-5一次観測点名指し細則の遡及適用)】
  **一次観測点**: doubt(a)(push安定完了)は`logs/git_push_block.log`(該当ALLOW行)・
  `git log origin/main..HEAD --oneline | wc -l`=0で既に機械確認済み。doubt(b)
  (backup branch中の平文旧秘匿値混入)は`git log --all -p -- mandate/approval_queue.md`
  でのパターン走査(旧ntfy_topic値文字列)で既に機械確認済み。本エントリ自体の再開
  (解除)条件は、doubt(a)(b)いずれかの追加観測ではなく**殿による削除可否の直接裁定**
  であり、機械的に自動評価できる条件式ではない。ゆえに本件の一次観測点は本ファイル
  `ID: AQ-008`エントリ直後の`状態:`行そのものである(`grep -n -A1 "^- ID: AQ-008" \
  mandate/approval_queue.md`で機械抽出可能。`状態: pending`から変化した時点が
  解除)。

  【追記・2026-08-26・subtask_180_D(足軽3号・cmd_180陣仕舞い・pending持ち越し記帳)】
  cmd_180陣仕舞い時点での持ち越し確認: 引き続きpendingのまま持ち越す。将軍が本夜
  (2026-08-26)殿へ諮ったが、殿は陣仕舞いの御下知をもって応じられ、裁可は下って
  いない。戻せない操作のため承認なきまま実行せず、次回へ持ち越す。AQ-008(旧backup
  branch削除)の実行は本サブタスクでも一切行っていない。

  【追記・2026-08-27・subtask_182_2(足軽5号・殿裁定執行=削除実行結果)】
  AQ-012送出完了(本ファイル同日付AQ-012追記参照)により「AQ-012次第」の条件が
  充足したため、削除前に当該branchが`origin`へ一度もpushされていないローカル
  専用refであることを確認した:
  削除前 `git branch -a | grep backup-cmd158-pre-history-purge-20260808-222447` →
  `  backup-cmd158-pre-history-purge-20260808-222447`(ローカルにのみ存在、
  `remotes/origin/...`形式のリモート追跡ブランチとしては非存在)。
  加えて`git ls-remote origin | grep backup-cmd158-pre-history-purge-20260808-222447` →
  ヒットなし(origin側に同名refが実在しないことを直接確認)。
  ローカル専用と確認できたため`git branch -D backup-cmd158-pre-history-purge-20260808-222447`
  を実行(出力: `Deleted branch backup-cmd158-pre-history-purge-20260808-222447
  (was be8e3c6).`)。
  削除後 `git branch -a | grep -i backup-cmd158` → ヒットなし(存在しないことを確認)。

- ID: AQ-009 | 日付: 2026-08-10 | 操作内容: `config/settings.yaml`
  `features.parent_cmd_done_gate_enabled` を off→enforce へ常用化移行
  (cmd_164 subtask_164_Bで建造、cmd_167で常用化) |
  理由: 新規flagの常用化判断は `instructions/karo.md`「新規feature flagの常用化判断」に従い
  approval_queue経由で殿が消化する運用。本件は殿裁定(Fable Q30経由・
  2026-08-10)により直接承認された |
  doubt: 実測根拠として以下を記すこと(貴殿自身が一次資料を確認して正確に記述せよ・援用禁止):
  (a) build時の実機検証(`gunshi_qc_164_B`——隔離環境でのALLOW/DENY/
      off即通過3パターン確認、既存bats37件+専用bats7件の回帰確認)
  (b) 常用化までの間に実際にstale assignedが5件再発した事実
      (subtask_167_A・cmd_165/166系列)——ゲートが`off`のまま
      運用実効性を持たなかった実例
  (c) 昇格根拠(非対称性): 誤denyは可逆(手戻りのみ)、放置は
      不可逆側(完了済みタスクの再実行という実害)——殿裁定(Fable
      Q30経由)の判断根拠をそのまま記すこと |
  状態: approved(承認者: 殿・Fable裁定Q30経由・2026-08-10、
  根拠: `queue/shogun_to_karo.yaml` cmd_167 ruling_source)

- ID: AQ-010 | 日付: 2026-08-26 | 操作内容: `config/settings.yaml`
  `dashboard_staleness.enabled` のobserve/enforce相当の常用化判断
  (cmd_168 subtask_168_Aで新設、既定値false=止血中) |
  理由: 新設接続則(Q37項目10・cmd_168、`mandate/verifiers.md`)により、
  新設flagは常用化判断がAQへ起票されるまで完了とみなさない。本flagは
  2026-08-26 14:54:59の偽陽性通知(cmd_166で解決済み・取消線付き項目を
  名指し)を受けた一時停止(止血)の実装であり、項目6(本修正——section限定
  パース等)完了後に常用化(observe/enforce)判断が必要になる |
  doubt: 常用化判断時に確認すること(本サブタスクでは承認しない・起票のみ):
  (a) 項目6本修正の完了とその実機検証結果
  (b) 停止期間中、代替可視化2経路(手空き通知pending行・セッション開始
      点検スイープ)が実際に機能し続けたことの実測(停止中に見落としが
      発生していないか)
  (c) 本修正後の再発試験(偽陽性が解消されたことの実機確認)——確認できる
      までは`enabled: false`(止血継続)を維持し、安易にtrueへ戻さないこと |
  状態: approved(2026-08-27・承認者: 殿)
  出典: 殿の直接裁定(2026-08-27・端末上の応答、将軍が3件を諮り3件とも承認)
  【追記・2026-08-26・cmd_170】doubt(a)充足: 修正3点(取消線除外/項目単位
  created_at/持ち越しマーカー)実装完了(subtask_170_A、commit 8dfa43d)、
  同族横展開点検で発見した2件目の同族欠陥(`build_fleet_idle_message()`
  未起票残タスク集計、取消線除外未適用)も是正済み、敵対的回帰テスト9件
  全PASS(subtask_170_B、commit 9afb384、既存16件と合わせ25/25 PASS)、
  実物データ(2026-08-26 14:54:59偽陽性事例——cmd_166で解決済み・取消線
  付きの📌スキル化候補項目)による再現実験で修正前(通知発火)→修正後
  (通知なし)の判定結果を実出力で確認した(軍師QC gunshi_qc_170_A・
  gunshi_qc_170_Bいずれもpass、独立再実験・独立再実行で一致確認済み)。
  doubt(b)(停止期間中の代替可視化2経路の機能継続実測)は継続確認中である。
  常用化(enabled: true)への変更の最終可否は殿の裁定を待つ。

  【追記・2026-08-26・subtask_178_B(足軽2号・Q42-5一次観測点名指し細則の遡及適用)】
  **一次観測点**:
  (a) 充足済み。`commit 8dfa43d`・`commit 9afb384`(`git show --stat <hash>`で内容確認可能)、
      `queue/reports/gunshi_report.yaml` task_id: gunshi_qc_170_A/gunshi_qc_170_Bのpass記録。
  (b) `logs/timing_events.jsonl`の`"event": "dashboard_stale_notified"`エントリ
      (`grep -c '"event": "dashboard_stale_notified"' logs/timing_events.jsonl`、
      2026-08-26T22:20時点実測=28件)。本修正(subtask_170_A/B)後もこのイベントが
      真の停滞に対してのみ発火し続けることが「代替可視化経路が機能し続けた」ことの
      実測点となる。🔴手空き通知pending行・セッション開始点検スイープ自体には専用の
      機械可読ログが存在しないため、現状ではこのイベントログが唯一の一次観測点である
      (専用ログの新設は本サブタスクの範囲外の指摘に留める)。
  (c) `logs/timing_events.jsonl`の`dashboard_stale_notified`イベントを、2026-08-26
      14:54:59型の入力(取消線付き📌スキル化候補項目)で再現した際、修正後は当該時刻
      以降に対応するイベントが記録されないこと(`grep`でタイムスタンプ以降のエントリ
      有無を確認)。

  【追記・2026-08-26・subtask_180_D(足軽3号・cmd_180陣仕舞い・pending持ち越し記帳)】
  cmd_180陣仕舞い時点での持ち越し確認: 引き続きpendingのまま持ち越す。
  cmd_170完了によりゲートは解放済み・裁定可能な状態。将軍が本夜(2026-08-26)殿へ
  有効化を具申したが、殿は陣仕舞いの御下知をもって応じられ、裁可は下っていない。
  次回へ持ち越す。

  【追記・2026-08-27・subtask_182_2(足軽5号・殿裁定執行=有効化+実機確認結果)】
  `config/settings.yaml`の`dashboard_staleness.enabled`を`false`→`true`へ変更
  (既存の他フィールド・コメントは無変更)。

  実機確認(`scripts/inbox_watcher.sh`の`check_dashboard_staleness()`を
  `__INBOX_WATCHER_TESTING__=1`テストガード経由で本番コードそのまま実行、
  モック実装ではない):
  ①**現行dashboard.md(既存エントリ)に対する実行**——実行前
  `logs/timing_events.jsonl`(2669行)・`logs/ntfy.log`(293行)、実行後
  いずれも行数無変化(新規`dashboard_stale_notified`イベント0件)。現行
  🚨要対応欄には取消線付き(解決済み)の18日超放置項目2件(2026-08-09付・
  📌スキル化候補/AQ-005)と持ち越しマーカー付きの17日超放置項目1件
  (AQ-008、`<!-- carryover_approved: true -->`)が存在し、いずれもcmd_170の
  3修正(取消線除外・項目単位created_at・持ち越しマーカー)により正しく
  除外され名指しされないことを確認した。
  ②**陽性対照(機構自体が実際に発火することの確認)**——本番コードを改変
  せず、隔離した一時ディレクトリ(実dashboard.mdは一切変更・接触せず)に
  取消線なし・持ち越しマーカーなしの模擬stale項目(created_at:
  2026-01-01T00:00:00)を追加した複製ファイルに対して同じ関数を実行した
  ところ、`🚨 24時間放置: - POSITIVE CONTROL TEST ITEM...`という通知
  相当の出力と`dashboard_stale_notified`イベント1件が正しく発火した
  (関数が常にno-opなのではなく、除外条件に合致しない場合は確実に機能する
  ことを確認)。

- ID: AQ-011 | 日付: 2026-08-26 | 操作内容: `config/settings.yaml`
  `features.staged_ignore_guard_enabled`(Q33(b)ガード、cmd_171
  subtask_171_Aで新設)の常用化判断(off/observe/enforce) |
  理由: 新設接続則(Q30(b)/Q37・cmd_168、`mandate/verifiers.md`)により、
  新設flagは常用化判断がAQへ起票されるまで完了とみなさない。本flagは
  「staging中に`git check-ignore`陽性のパスがあればdeny」する新規ガード
  (`scripts/pretooluse_staged_ignore_guard.sh`)の有効化フラグであり、
  dashboard.md誤追跡(cmd_166・commit 4a27ad7)・config/settings.yaml
  誤追跡(cmd_158-B)の再発防止を目的とする。通常の新規flag既定off運用
  (cmd_144議題5・cmd_147制定)とは異なり、本cmd_171の command「工程2
  ガードの性格」節がenforce直行を明示指示している——Q37裁定が
  `4a27ad7`のblobを許容した根拠3点セットの1本(ガード成立)がこの
  enforce化自体であるため、通常の段階昇格(off→observe→enforce)を
  待たずに直接enforceとした |
  doubt: (a) `config/settings.yaml`の値は本サブタスクでenforceへ設定済み
  だが、フックとして実際に発火させるための`.claude/settings.json`
  PreToolUse配列への登録が2026-08-26時点で未実施(本サブタスクの
  allowed_pathsが`scripts`ディレクトリのみでconfig/settings.jsonを
  含まないため、登録は別サブタスクの担当となる。登録が済むまでconfig値を
  enforceにしても実際には評価されず無防備のままである点に留意)
  (b) 実機検証(足軽1号・2026-08-26): dashboard.md/config/settings.yaml
  各々への`git add`明示指定を2例ともDENYで捕捉、正常staging(`git add
  scripts/inbox_write.sh`等、.gitignoreで明示許可済みの既存tracked
  ファイル)はALLOWで通過することを確認(誤検知試験)。加えて隔離
  テストリポジトリでの検証により、`git add .`・`git commit -am`
  (ワイルドカードstaging)経路でも「既にtrackedだがignore陽性」の
  ファイルを正しく捕捉することを確認した
  (c) 🔴重大な副作用の発見: 本リポジトリには現在13件、tracked済みだが
  `git check-ignore -q --no-index`陽性(=.gitignoreのwhitelist方式
  allowlistに未掲載)のファイルが既に存在する
  (`scripts/pretooluse_git_push_block.sh`・`scripts/pretooluse_yaml_guard.sh`
  等、本ガード自身が依拠する既存PreToolUseフック本体を含む13件——足軽1号が
  `git ls-files`全298件を`git check-ignore -q --no-index`で走査し実測)。
  これらは事故ではなく.gitignoreのallowlist更新漏れ(新規スクリプト追加時に
  `!scripts/<file>`行の追記が徹底されていなかった)と見られる。本ガードを
  ワイルドカード(`git add .`/`-A`/`git commit -a`系)経路も含めて有効化
  すると、これら13件を含む`git add .`/`git commit -a`が今後すべてdeny
  されるため、フック登録(a)に先立って.gitignoreのallowlistへこの13件を
  追記するか、殿がこの副作用を許容のうえ登録を進めるかの判断が必要 |
  状態: approved
  追記(cmd_177 subtask_177_A・足軽5号・2026-08-26): doubt(a)(c)を以下のとおり解消。
  (a) `.claude/settings.json`のPreToolUse配列へ`scripts/pretooluse_staged_ignore_guard.sh`
  (matcher: "Bash", timeout: 5、既存`pretooluse_git_push_block.sh`と同作法)を登録し、
  本番PreToolUse経路での実発火をDENY/ALLOW両方の実ログ
  (`logs/staged_ignore_guard.log`session=1dc240f1-b687-4a16-8a40-e3fc5a2b392d、
  2026-08-26T21:40:24〜27+09:00の3行)で確認した(手動piped実行ではない)。
  (c) 13件を1件ずつ判定(機械的一括処理せず): 全13件とも「本来trackedであるべき
  ファイル」(生成物/共有インフラスクリプト/フック本体)であり、allowlist掲載漏れと
  判定した。`.gitignore`へ`!<path>`を個別追記して解消した。untrack候補は0件
  (13件詳細は`queue/reports/ashigaru5_report.yaml` task_id: subtask_177_A参照)。

- ID: AQ-012 | 日付: 2026-08-26 | 操作内容: 未push commit群(16件、
  `AQ_APPROVED_ID=AQ-012`を明示付与しての`git push origin main`実行)の
  承認可否(cmd_171 subtask_171_A起票・工程5=push実行自体は殿承認後の
  別サブタスクが担当) |
  理由: Q37裁定(cmd_168制定)は、dashboard.mdの意図せぬ再追跡commit
  `4a27ad7`のblobを非除去のまま(b)許容してpushすることを、(1)秘匿値ゼロの
  独立確定 (2)Q33(b)再追跡拒否ガードの成立 (3)ブロッカー実害(未push蓄積)
  の3点セットを条件に認めた。cmd_171 subtask_171_Aにより(2)のガード
  (`scripts/pretooluse_staged_ignore_guard.sh`)を本日新規建造しconfig値を
  enforceへ設定(接続=`.claude/settings.json`登録は別途要、AQ-011参照)。
  本AQは、上記3点セットが実際に揃った状態で殿がpushを消化するための
  起票である |
  doubt: (a) 未push件数の自己再実測(足軽1号・2026-08-26、`git fetch
  origin main`後`git log origin/main..HEAD --oneline | wc -l`実行、
  将軍の値〈16件〉を援用せず自ら独立測定): 16件。cmd別内訳: cmd_164系3件
  (c575056・629a3cf・f768123)、cmd_165系4件(d6eabfe・36e063c・72fda48・
  f7697ff)、cmd_166系3件(3c472fa・4a27ad7・b9c4974)、cmd_167系2件
  (67c3021・4203de1)、cmd_168系4件(a20fca0・f20575b・8489d87・c6e543d)。
  合計16件で将軍実測値と一致した(が本doubtは援用ではなく独立再実測で
  ある。原則3)
  (b) 秘匿値走査結果(足軽1号・2026-08-26、`git log -p origin/main..HEAD`
  全3716行を`ntfy_topic`/`api[_-]?key`/`secret`/`token`/`password`/
  `bearer`/`AKIA[0-9A-Z]{16}`/`ghp_`/`sk-`等のパターンで走査、加えて
  20文字以上の英数トークンを機械的に列挙し目視確認): 現行ntfy_topic値
  (`<ntfy_topic旧値>`)およびそのプレフィックスの一致なし。
  「ntfy_topic」という語自体はdecisions_journal.md記帳文中に複数出現するが、
  いずれも「過去にbackup branchで平文混入が発覚し除去した」という記述内の
  言及であり、平文の秘匿値そのものではない。20文字以上トークンの機械列挙
  (93件)も目視確認したが、全て識別子・関数名・ファイル名であり秘匿値には
  該当しない。**平文秘匿値の混入は確認されなかった(0件)**
  (c) `4a27ad7`のblobを含む旨: 16件中に`4a27ad7 feat(cmd_166
  subtask_166_B): add Skill documentation for check_runtime_reflection`
  (dashboard.md誤追跡分1171行を含む)が含まれる。Q37裁定でこれが許容された
  経緯(`mandate/decisions_journal.md`168〜172行目を実読して引用):
  「本許容の根拠は無害確認(秘匿値ゼロの独立確定)+ガード成立(Q33(b)
  再追跡拒否ガード建造)+ブロッカー実害(未push12件、記帳時点15件)の
  3点セットであり、いずれか欠く場合は除去を原則とする。本許容は個別事案
  限りであり、『意図的除外は破ってよい』という一般運用への転化を禁ずる」
  (168行目)。「前例化防止則」として「本許容は前例としない」旨も明記
  されている(170行目)。🔴上記3点セットのうち(2)ガード成立は本サブタスクで
  スクリプト自体は建造・実機検証済みだが、`.claude/settings.json`への
  接続が別途必要(AQ-011 doubt(a)参照)——**接続未完了の間はガードは
  実際には発火しない**ため、殿がpush消化を判断する際はこの点を踏まえる
  こと |
  状態: approved(2026-08-27・承認者: 殿)
  出典: 殿の直接裁定(2026-08-27・端末上の応答、将軍が3件を諮り3件とも承認)
  追記(cmd_177 subtask_177_A・足軽5号・2026-08-26): **Q37 3点セットの(2)ガード成立が
  真になった**。`.claude/settings.json`のPreToolUse配列へ`pretooluse_staged_ignore_guard.sh`
  を登録し、本番PreToolUse経路での実発火を実ログで確認した(AQ-011 doubt(a)追記と同一の
  実測。config値がenforceであることのみを根拠とせず、実発火のみを証拠として受理):
  `logs/staged_ignore_guard.log`session=1dc240f1-b687-4a16-8a40-e3fc5a2b392dの
  2026-08-26T21:40:24〜27+09:00に(a) `git add dashboard.md`→DENY実発火、(b) `git add
  scripts/inbox_write.sh`(既存allowlist済み正常ファイル)→ALLOW実発火、(c) `git add
  scripts/pretooluse_git_push_block.sh`(本cmdでallowlist追記した13件の1つ)→ALLOW実発火
  (誤検知解消の実証)、の3行を記録済み。**AQ-012の状態はpendingのまま変更していない**
  (push承認は殿の専権)。

  【追記・2026-08-26・subtask_178_B(足軽2号・Q42-5一次観測点名指し細則の遡及適用)】
  **一次観測点**(Q37 3点セット):
  (1) 秘匿値ゼロ: doubt(b)記載のパターン走査(`ntfy_topic`/`api[_-]?key`/`secret`/
      `token`/`password`/`bearer`/`AKIA[0-9A-Z]{16}`/`ghp_`/`sk-`等)を
      `git log -p origin/main..HEAD | grep -iE '...'`で再実行可能。
  (2) ガード成立: `logs/staged_ignore_guard.log`
      (session=1dc240f1-b687-4a16-8a40-e3fc5a2b392d、2026-08-26T21:40:24〜27+09:00の
      DENY/ALLOW実発火3行、`grep 1dc240f1-b687-4a16-8a40-e3fc5a2b392d
      logs/staged_ignore_guard.log`)。
  (3) ブロッカー実害: `git log origin/main..HEAD --oneline | wc -l`(doubt(a)実測=16件、
      殿がpush消化前に自ら再実測可能)。
  本エントリ自体の再開(承認/却下)条件は上記3点セットの機械観測ではなく**殿による
  push実行可否の直接裁定**であり、一次観測点は本ファイル`ID: AQ-012`エントリ直後の
  `状態:`行そのものである(`grep -n -A1 "^- ID: AQ-012" mandate/approval_queue.md`で
  機械抽出可能)。裁可後の実行確認は`logs/git_push_block.log`の`AQ_APPROVED_ID=AQ-012`
  に対応するsession記録で事後確認できる。

  【追記・2026-08-26・subtask_171_B(足軽5号・doubtの陳腐化解消——本夜の大量作業
  〈cmd_170〜179〉により未push件数が16件から増加した件の再実測)】
  ①再実測した未push件数(将軍実測33件は援用せず、貴殿自身が`git fetch origin main`後
  `git log origin/main..HEAD --oneline | wc -l`を独立実行): **33件**。将軍実測値と一致
  したが、本doubtは援用ではなく独立再実測である(原則3)。
  cmd別内訳(`git log origin/main..HEAD --oneline | grep -oE '\(cmd_[0-9]+ ' | sort |
  uniq -c`で機械抽出、括弧付きプレフィックス一致でカウント。タグなし1件は個別確認):
  cmd_179×4(4b3b104・9d6c9f8・1c28901・e07e5f4)、cmd_170×4(fa2e30e・9afb384・
  fc67413・8dfa43d)、cmd_168×4(c6e543d・8489d87・f20575b・a20fca0)、cmd_165×4
  (f7697ff・72fda48・36e063c・d6eabfe)、cmd_166×3(b9c4974・4a27ad7・3c472fa)、
  cmd_164×3(f768123・629a3cf・c575056)、cmd_178×2(d7e23d6・5510b62)、cmd_167×2
  (4203de1・67c3021)、cmd_177×1(1794a55)、cmd_176×1(2f8ac70)、cmd_175×1
  (97093b0)、cmd_174×1(6ebe88c)、cmd_173×1(43c2c8f)、cmd_171×1(4f79655)、
  cmdタグなし×1(e696a70 "chore: regenerate stale derived instruction files")。
  合計33件で内訳と一致。**整合性検算**: 既存doubt(a)の16件内訳(cmd_164×3・
  cmd_165×4・cmd_166×3・cmd_167×2・cmd_168×4=16)は今回も完全一致(この5cmdへの
  新規commit追加なし)。増分17件はすべてcmd_170以降(cmd_170×4+cmd_171×1+cmd_173×1
  +cmd_174×1+cmd_175×1+cmd_176×1+cmd_177×1+cmd_178×2+cmd_179×4+タグなし×1=17)。
  33=16+17で算数整合。

  ②秘匿値走査(`git log -p origin/main..HEAD`全6542行〈`git diff`形式、doubt(a)の
  「全3716行」から件数増に伴い増加〉を`ntfy_topic`/`api[_-]?key`/`secret`/`token`/
  `password`/`bearer`/`AKIA[0-9A-Z]{16}`/`ghp_`/`sk-ant`で機械走査): パターン一致
  24行。うち23行はdecisions_journal.md/approval_queue.md自身の記帳文中における
  「過去にntfy_topic平文混入が発覚し除去した」等の**言及**であり、平文の秘匿値
  そのものではない。🔴残り1行(本ファイル内、subtask_171_A起票のdoubt(b)自身の文中)に
  現行ntfy_topic値`<ntfy_topic旧値>`が実際にプレーンテキストで出現する
  (doubt(b)が「この値の一致なし」を示す目的で値自体を引用したため、皮肉にも引用行
  自体が新たな出現箇所になっていた)。
  **クロスチェック**: `git grep`でorigin/main全体を独立走査した結果、この同一値は
  `mandate/decisions_journal.md:136`(commit `2059325`, cmd_160 subtask_160_C、
  2026-08-09、既にpush済み)に既に存在することを確認した。したがって本doubt(b)
  1行は「今回の未push分で新規に晒される秘匿値」ではなく、既に`origin/main`上で
  公開済みの値の再掲である。**push可否の判断への影響**: 本AQ-012の33件push自体が
  この値を新たに公開するものではない(既に2026-08-09時点でpush済み・公開済み)ため、
  Q37 3点セット(1)秘匿値ゼロの結論(0件=新規混入なし)は維持できる。
  **ただし別建てで重大**: 現行ntfy_topic値(`<ntfy_topic旧値>`、当時の
  `config/settings.yaml`の現在値と一致)が既に`origin/main`上で公開済みであるという
  事実は、本cmd_171の範囲外ではあるが、ntfy通知チャンネルの実質的アクセストークンが
  既に漏洩状態にあることを意味する。ローテーション要否の判断を殿・軍師へ別途仰ぐ
  ことを推奨する(本doubtでは対応事項に含めず、発見事実のみを記録)。

  【cmd_180工程2注記(2026-08-26)】本doubt(b)内に平文出現していたntfy_topic旧値
  (本注記直前の2箇所、および上記doubt(b)冒頭付近の1箇所、計3箇所)は、殿裁定による
  トピックローテーション(cmd_180)に伴い`<ntfy_topic旧値>`へ置換除去した(理由:
  秘匿値を記帳本文へ平文で書かない規律の遡及適用。値の置換のみで記録の趣旨・
  発見事実・判断根拠に変更なし)。「ローテーション要否の判断を殿・軍師へ別途仰ぐ
  ことを推奨する」という本doubtの提言は、本cmd_180によって実行された。

  ③`4a27ad7`のblob包含確認: 再実測した33件のcmd別内訳中、cmd_166×3件の1つとして
  `4a27ad7 feat(cmd_166 subtask_166_B): add Skill documentation for
  check_runtime_reflection`が引き続き含まれることを確認した(上記①のリスト参照)。
  Q37裁定での許容経緯は既存doubt(c)記載のとおり変更なし。

  **AQ-012の状態は`pending`のまま変更していない**(push承認は殿の専権)。

  【追記・2026-08-26・subtask_180_D(足軽3号・cmd_180陣仕舞い・pending持ち越し記帳)】
  殿は2026-08-26 23:27に条件付き承認(残存ゼロ確認が条件)。subtask_180_Cが改訂
  走査を実施したところ、未push3commit(4f79655/56f120c/b1775d7)のpatch自体に
  旧値が計6箇所残存することを発見し送出を再停止(軍師QC PASS済み)。現行ファイル
  内容はクリーンだが、解消には当該3commitの履歴書換(amend/squash)が必要——これは
  D003および本cmd自身の禁止事項によりcmd_180の射程外の統治判断であり、通常手段
  では解消不能なジレンマである(軍師評価)。将軍が殿裁定を仰ぐべき最重要案件として
  持ち越す。本追記自体は`状態: pending`を変更するものではなく、持ち越し事由の
  記帳のみである。

  【追記・2026-08-27・subtask_182_2(足軽5号・殿裁定執行=送出実行結果)】
  殿は2026-08-27 20:22頃、端末上の応答でAQ-012含む3件すべてを承認された
  (出典: `queue/shogun_to_karo.yaml` id: cmd_182 ruling_source)。本追記の
  直前で状態欄を`approved(2026-08-27・承認者: 殿)`へ先行更新(技術ガード
  `pretooluse_git_push_block.sh`がpush成立の事前条件として本ファイルの状態欄を
  要求するため)したうえで、以下を実行した。

  ①再実測件数(`git fetch origin main`後`git log origin/main..HEAD --oneline |
  wc -l`、将軍実測・前回report実測いずれも援用せず独立再実測): **42件**
  (subtask_182の前回実測42件と一致・値・走査手法とも変更なし)。cmd別内訳:
  cmd_181×4・cmd_179×4・cmd_170×4・cmd_168×4・cmd_165×4・cmd_180×3・
  cmd_166×3・cmd_164×3・cmd_178×2・cmd_171×2・cmd_167×2・cmd_177×1・
  cmd_176×1・cmd_175×1・cmd_174×1・cmd_173×1・cmd_172×1・no_cmd_tag×1
  (詳細は`queue/reports/ashigaru5_report.yaml task_id: subtask_182`参照)。

  ②push実行結果: `AQ_APPROVED_ID=AQ-012 git push origin main`実行、
  `543666a..a04af3d main -> main`でリモート反映。実行後
  `git log origin/main..HEAD --oneline | wc -l` = **0**、
  `logs/git_push_block.log`に対応する`ALLOW`行(`[2026-08-27T20:48:05+09:00]
  ALLOW mode=enforce session=8023a98f-07fa-48a9-a328-31d4e08653ef tool=Bash`)
  を実出力で確認。

  ③旧ntfy_topic値の公開ツリーからの消失確認(値そのものは平文で書かない・
  cmd_180制定則遵守、ファイル名変数へ一時格納した機械照合のみで実施):
  送出前=`git grep -c "$OLDVAL" origin/main -- . | wc -l` = **1**
  (該当ファイル: `mandate/decisions_journal.md`)、送出後=同コマンド再実行
  で**0**。北極星が述べた「旧値は`origin/main`の現行ツリーに今この瞬間も
  存在し、`b1775d7`送出で初めて消える」という主張と実測が一致した。

  本cmd_182の真の成果(件数ではなく公開ツリーからの旧値消失)を機械照合で
  達成した。

- ID: AQ-013 | 日付: 2026-08-27 | 操作内容: `config/settings.yaml`
  `features.secret_guard_enabled`(秘匿値pre-commitガード、cmd_183-2
  subtask_183_Bで新設)の常用化判断(off/observe/enforce) |
  理由: 新設接続則(Q30(b)/Q37・cmd_168、`mandate/verifiers.md`)により、
  新設flagは常用化判断がAQへ起票されるまで完了とみなさない。本flagは
  `git commit`(-a/-am/--all派生含む)検出時にstaged diffの追加行のみを
  P1〜P4(既知プレフィックス/高エントロピー16進・base64/代入文脈/URL
  埋め込み)で走査しdenyする機構であり、既定値offのまま起票のみを行う
  (subtask_183_Bでは常用化判断そのものは行わない) |
  doubt: 常用化判断時に確認すること(本サブタスクでは承認しない・起票のみ):
  (a) observe段での実運用staged diffに対する誤検知件数の実測(0件または
      許容水準であることの確認。既存2ガード〈git_push_block/
      staged_ignore_guard〉の前例に照らし、この段階を飛ばすべきではない)
  (b) 本ガードは**自己(commit操作)を観測対象に含む機構**である
      (Q23②)。dashboard.md「📋未解除caveat追跡」欄に登録済みのcaveat
      (一次観測点: `logs/secret_guard.log`に対する
      `grep -c 'ALLOW\|DENY\|WOULD-DENY' logs/secret_guard.log`)の解除
      状況もあわせて確認すること
  (c) subtask_183_B建造時点で本ガード自身は`config/settings.yaml`
      (実際の走査対象diff)には触れず、隔離環境(一時repo・
      `SECRET_GUARD_*`環境変数注入)でのみ真陽性・偽陽性回避を検証した
      (合成ダミー値のみ使用・実在の秘匿値は不使用)。本番commit経路への
      接続確認は observe modeで一時的に行い(`logs/secret_guard.log`に
      WOULD-DENY実発火を記録済み)、確認後 off へ戻して起票している。
      常用化判断時は、この一時観測で得たWOULD-DENYの実例
      (`tests/unit/test_pretooluse_secret_guard.bats`自体が合成秘匿値
      形状の記述を含むためテストファイル自身のcommitがWOULD-DENYと
      判定された実例)を、真陽性の一種として扱うか、テストフィクスチャの
      除外設計を要するかも合わせて検討されたい |
  状態: approved(2026-08-27・承認者: 殿・裁定内容: observe へ〈enforceでは
  ない〉)——出典: `queue/shogun_to_karo.yaml` id: cmd_184 ruling_source
  (「将軍が3件を諮り、殿は(1)AQ-013=『observe へ』…と裁定された」)。
  subtask_184(足軽5号)にて`config/settings.yaml`
  `features.secret_guard_enabled`をobserveへ実際に変更済み(commit 55fad70
  はclear_idle.sh tracked化、config変更自体はuntrackedにつき別途反映)。
  出典: `queue/tasks/ashigaru2.yaml` task_id: subtask_183_B(cmd_183-2
  対応事項4(b)、殿裁可・フィーチャーフリーズ〈cmd_138〉のカーブアウト)

  🔴起票者注記(足軽2号): 本AQエントリが所在する`mandate/approval_queue.md`
  は、subtask_183_Bのtask YAML `allowed_paths`に明示列挙されていない
  (`scripts/pretooluse_secret_guard.sh`・`.claude/settings.json`・
  `.gitignore`・`config/settings.yaml`・`config/settings.yaml.example`・
  `tests/unit/test_pretooluse_secret_guard.bats`・`dashboard.md`・
  `mandate/decisions_journal.md`・`queue/reports/ashigaru2_report.yaml`の
  9件のみが列挙されている)。一方で対応事項4(b)は「常用化判断はAQへ起票
  すること」をSKIP=FAIL条件として明示指示しており、本ファイルへの追記
  なしにはこの受け入れ条件を満たせない。両者の矛盾は貴殿(足軽2号)の
  裁量では解消せず、以下の判断基準に基づき前進を選んだ: (1)本追記は
  既存エントリを一切変更しない純追記であり、書式は直前のAQ-008〜012の
  慣行に完全に倣っている(2)`mandate/decisions_journal.md`(同じmandate/
  配下・同じ追記専用文書)は既にallowed_pathsに含まれており、本ファイルの
  性質(追記専用の判断台帳)は同一である(3)`scope_check_advisory`は
  advisory記録のみ(強制ブロックなし)であることを`config/settings.yaml`で
  確認済み——技術ガードによる不可分の矛盾(subtask_182が踏んだ
  AQ_APPROVED_ID型の矛盾)とは性質が異なる。それでもallowed_paths列挙漏れ
  である可能性は残るため、家老・軍師の判断でscope_check advisory結果を
  確認されたい。

  🔴追記(足軽5号・subtask_184・cmd_184、殿裁定によりoffからobserveへ移行
  実施後): enforce昇格判断のための**条件式**(Q35期日禁止則につき暦日では
  書かない)を以下のとおり定める。常用化判断はこの条件式の充足を機械確認
  してから行うこと:
  1. **observe段でのWOULD-DENY実測件数と真陽性/偽陽性内訳が確認できること**。
     一次観測点: `logs/secret_guard.log`。機械判定コマンド:
     `grep -c 'WOULD-DENY' logs/secret_guard.log`(総件数)、
     `grep 'WOULD-DENY' logs/secret_guard.log | grep -oE '[a-z_./]+\.(bats|sh|yaml|md):[0-9]+' | sort | uniq -c`
     (ファイル別内訳、テストフィクスチャ由来か本番commit由来かの切り分け用)。
     observe化直後(2026-08-27 22:26時点)の基準値: 総件数1件(observe化前の
     subtask_183_B隔離検証時の記録、`tests/unit/test_pretooluse_secret_guard.bats`
     自身の合成ダミー値によるもの=真陽性〈パターンとしては該当〉かつ実害なし
     〈実在の秘匿値ではない〉のテストフィクスチャ起因)。これ以外に新規の
     WOULD-DENYが本番commit経路(config/journal/approval_queue/dashboard等の
     実務ファイル)から観測され、かつそれが真の秘匿値混入(誤検知でない)で
     あった場合は、直ちに家老・軍師へ報告し常用化判断を待たず個別に対処
     すること。
  2. **テストフィクスチャ(`tests/unit/test_pretooluse_secret_guard.bats`等、
     合成ダミー値を含むファイル)の除外設計の要否について結論が出ている
     こと**。🔴この問いが未解決のままではenforce昇格の条件を満たさない
     (結論の中身は「除外設計を導入する」「導入しない(誤検知として許容
     する)」のいずれでもよいが、いずれかの結論に到達していることが条件
     そのものである)。
  3. 上記1・2に加え、既存の姉妹ガード(git_push_block/staged_ignore_guard/
     yaml_guard)がenforce昇格時に用いた前例条件——評価母数が一定件数以上
     確保されていること・複数稼働セッションに跨っていること——も参考に
     すること(具体的な数値基準は常用化判断時に家老・軍師が個別に定める)。
  4. 🔴🔴**ブロッカー条項(subtask_187・cmd_187殿裁定〈2026-08-27・
     「持ち越す」〉)**: `scripts/pretooluse_secret_guard.sh`のcwd誤判定
     (subtask_186_2発見・2026-08-27)が根治されるまで、上記1・2・3が
     形式上充足していても本ガードをenforceへ昇格してはならない。
     理由: 現在observeゆえ実害は無いが、enforceへ昇格した瞬間に
     「対象リポジトリの解決を`SCRIPT_DIR`固定(=常に本リポジトリ自身)で
     行っている」欠陥が、外部リポジトリでのcommit時に秘匿値検知漏れとして
     実害化する(`pretooluse_staged_ignore_guard.sh`がcmd_186で踏んだ欠陥1
     〈cwd誤判定〉と同型)。🔴一次観測点(本サブタスクで実読・特定):
     `scripts/pretooluse_secret_guard.sh`27行目
     `REPO_DIR="${SECRET_GUARD_REPO_DIR:-$SCRIPT_DIR}"`が、
     `pretooluse_staged_ignore_guard.sh`のcmd_186是正(REPO_DIR解決を
     hook入力cwdからの`git rev-parse --show-toplevel`によるpython側動的
     解決へ置き換え、解決失敗時はfail-safeで`exit 0`)と同型の実装へ
     置き換わっていることが充足基準である。機械判定コマンド:
     `grep -n 'REPO_DIR=\"\${SECRET_GUARD_REPO_DIR:-\$SCRIPT_DIR}\"'
     scripts/pretooluse_secret_guard.sh`の出力が**0件**になっていること
     (=固定パス代入行が消滅し、動的解決に置換済みであること)。

- ID: AQ-014 | 日付: 2026-08-27 | 操作内容: 未push commit群(5件、
  `AQ_APPROVED_ID=AQ-014`を明示付与しての`git push origin main`実行)の
  承認可否 |
  理由: cmd_183(Q33(b)ガード本体〈`scripts/pretooluse_staged_ignore_guard.sh`〉
  のtracked化+秘匿値pre-commitガード〈`scripts/pretooluse_secret_guard.sh`〉
  建造)完了時点の帳簿締めとして起票する |
  doubt:
  (a) 未push件数の再実測(subtask_183_C独立測定): `git fetch origin main &&
      git log origin/main..HEAD --oneline | wc -l` = **5件**。cmd別内訳
      (`git log origin/main..HEAD --oneline | grep -oE '\(cmd_[0-9]+' |
      sort | uniq -c`): cmd_182×1(71d7165)・cmd_183×4(7ff45e1/5c6d9df/
      08c9f2e/4116aca)。🔴本件数は本AQ-014起票commit自体を含まない
      (起票時点の実測値であり、起票commit自体が加わることでpush直前の
      実件数は6件となる。この扱いはAQ-013起票時と同一の測定方法)
  (b) 秘匿値走査(a)差分走査: `git log -p origin/main..HEAD`への
      パターン走査(`ntfy_topic|api[_-]?key|secret|token|password|bearer|
      AKIA[0-9A-Z]{16}|ghp_|sk-ant`)で70件ヒット。実出力を確認したところ
      いずれも(i)変数名・関数名・設定キー名(`secret_guard_enabled`・
      `SECRET_GUARD_*`環境変数名等)への語句マッチ、(ii)journal/AQ本文中の
      経緯記述(プレースホルダ`<ntfy_topic旧値>`への言及、本件を含め3件)、
      (iii)テストファイル(`tests/unit/test_pretooluse_secret_guard.bats`)
      内の合成ダミー値(`sk-ant-AAAA...`・`ghp_AAAA...`等、全てA連続や
      既知のダミー形状であり実在の秘匿値ではない)であり、新規の実秘匿値は
      検出されなかった
  (c) 秘匿値走査(b)全tracked file現行内容走査: `git ls-files`列挙の
      全trackedファイルに対する同パターン走査で436行(83ファイル)が
      マッチしたが、大半は(a)と同様の語句一致(変数名・ドキュメント中の
      語彙)。値保持形状(`AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|
      sk-ant-[A-Za-z0-9_-]{20,}|ntfy_topic[:=]値`)に絞った再走査では、
      テストファイル内の合成ダミー値6件のみがヒットし、実秘匿値は0件。
      `config/settings.yaml`・`config/ntfy_auth.env`(実値ファイル)は
      いずれもtracked化されておらず(`.example`/`.sample`版のみtracked)、
      現行ツリーに実秘匿値ファイルの追跡混入なし
  (d) 🔴旧ntfy_topic値のプレースホルダ`<ntfy_topic旧値>`の残存(cmd_180で
      置換除去済み・既承認の既知残存事項): 全trackedファイル現行内容中に
      8箇所(`mandate/approval_queue.md`×4・`mandate/decisions_journal.md`
      ×2・`tests/unit/test_pretooluse_secret_guard.bats`×2、うち後者2件は
      偽陽性回避テストのプレースホルダ文字列そのもの)。値自体は伏字化
      済みであり実害なし。差分走査でも同プレースホルダが3件出現(経緯記述
      の引用によるもの)。この許容範囲は変わらず、新規の平文露出は伴わない
  状態: approved(2026-08-27・承認者: 殿)——出典: `queue/shogun_to_karo.yaml`
  id: cmd_184 ruling_source(「殿は…(2)AQ-014=『AQ-013後に送出する』…と
  裁定された」)。🔴記帳順序についての注記(足軽5号・subtask_184):
  acceptance_criteria【5・記帳】は「実際に操作を完了した後に」状態欄を
  approvedへ更新すると定めるが、`scripts/pretooluse_git_push_block.sh`
  (cmd_159)は本欄が`approved`を含むことを送出の前提条件としており、
  記帳を送出の後に回すと送出自体が技術的に不可能になる(deny)。両者は
  文言上の矛盾であり、貴殿(足軽5号)の裁量では解消せず、以下の判断基準で
  前進を選んだ: (1)殿の承認そのものは既に成立済みである(本欄の更新日時
  より前、cmd_184 ruling_source記載の「2026-08-27 22:2x頃」の端末上の
  応答をもって)——本更新は新たな承認を生むものではなく、既に下された
  裁定を記帳するのみである (2)送出直前の再実測(対応事項3)は
  本記帳の**前**に完了済みであり、記帳が送出を追い越して先行承認を
  捏造する形にはなっていない (3)AQ-013の起票者(足軽2号)が同種の
  allowed_paths矛盾に直面した際に採った「純追記・既存慣行踏襲・矛盾は
  記録し家老/軍師の確認に委ねる」という前進方針に倣った。家老・軍師の
  判断でこの順序自体の是非(acceptance_criteria文言の是正要否)を確認
  されたい。
  出典: `queue/tasks/ashigaru3.yaml` task_id: subtask_183_C(cmd_183
  acceptance_criteria【6】、殿の専権事項につき送出は行わず起票のみ)

- ID: AQ-015 | 日付: 2026-08-27 | 操作内容: 未push commit群
  (`AQ_APPROVED_ID=AQ-015`を明示付与しての`git push origin main`実行) |
  理由: cmd_187(陣仕舞い)の殿裁定「未push3件は送出する」(2026-08-27・
  端末上の応答「送出する」)を執行する |
  doubt: 🔴**(1) 送出直前の再実測(subtask_187・本エントリ起票時点で自ら
  再実測、将軍の「3件」を援用せず独立測定)**: `git fetch origin main`
  実行後`git log origin/main..HEAD --oneline | wc -l` = **4件**。
  内訳(`git log origin/main..HEAD --oneline | grep -oE '\(cmd_[0-9]+' |
  sort | uniq -c`): cmd_184×1(e7cb1f1)・cmd_186×2(df9392a, edc1180)・
  cmd_187×1(5e6c58c、本サブタスクのAQ-013ブロッカー条項追記commit)。
  合計検算: 1+2+1=4件、総数4件と一致。🔴本件数は本AQ-015起票commit自体を
  含まない(AQ-013/AQ-014起票時と同一の測定方法。起票commitが加わることで
  push直前の実件数は5件となる)。
  🔴**(2) 秘匿値走査・両手法**:
  (a) 差分走査(`git log -p origin/main..HEAD`、パターン
  `(ntfy_topic|api[_-]?key|secret|token|password|bearer|
  AKIA[0-9A-Z]{16}|ghp_|sk-ant|-----BEGIN)`大小文字区別無し): 23件
  ヒット。追加行のみ(`grep -E '^\+'`)に絞った値保持形状パターン
  (`AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|
  ntfy_topic[:=][^<# ]`)での再走査は**0件**。広域ヒット23件を1件ずつ
  実出力確認した結果、残り4件を除く19件は`secret_guard`/`SECRET_GUARD`
  等の変数名・関数名一致であり、残り4件は(i)本サブタスク自身のcommit
  メッセージ中の"secret-detection"という語句1件、(ii)コード変数名
  `seg_tokens`/`staged_paths`が偶然"token"を部分一致した1件、(iii)
  `mandate/decisions_journal.md`のcmd_182 CORRECTエントリ中でntfy_topic
  ローテーション経緯を説明する散文1件——いずれも実秘匿値ではないことを
  確認した(**ゼロ確認**)。
  (b) 全tracked file現行内容走査(`git ls-files`列挙、同パターン):
  広域96件ヒット。値保持形状パターンへ絞った再走査では9件ヒットし、
  内訳は`.gitleaks.toml`のgitleaks検知規則定義2件(実値ではなく検知用
  正規表現・プレースホルダ"your-topic"等)、
  `mandate/approval_queue.md`のAQ-002本文中の経緯記述1件(値自体は
  伏字化済み・cmd_149でローテーション済みの既承認既知事項)、
  `tests/unit/test_pretooluse_secret_guard.bats`の合成ダミー値6件
  (`sk-ant-AAAA...`・`ghp_AAAA...`、いずれも全A連続の既知ダミー形状、
  AQ-013/AQ-014で既に真陽性〈実害なし〉と判定済みの同一フィクスチャ)
  であり、新規の実秘匿値は0件。`git ls-files | grep -E
  'settings\.yaml$|ntfy_auth\.env$'`は空——実値ファイル
  (`config/settings.yaml`・`config/ntfy_auth.env`)は引き続き
  未trackedであることを確認した。
  状態: approved(2026-08-27・承認者: 殿)——出典:
  `queue/shogun_to_karo.yaml` id: cmd_187 ruling_source(「殿の直接下命
  (2026-08-27 23:5x)『本日はこれで陣仕舞い可能か』+将軍の諮問への裁定
  2件: …(2)未push3件=『送出する』」)。cmd_182/cmd_184の教訓(push系AQは
  技術ガード`pretooluse_git_push_block.sh`の事前条件として状態欄の
  approved化をpushより先に要求する)に倣い、本状態欄は送出実行前に
  approvedとして記帳する(記帳順序の是非についてはAQ-014起票者〈足軽5号〉
  の注記と同一の判断基準に倣う)。
  備考: 実際のpush・`AQ_APPROVED_ID=AQ-015`付与・`ALLOW`ログ確認は
  本エントリ起票直後に本サブタスク(subtask_187)自身が引き続き実施する。

- ID: AQ-016 | 日付: 2026-09-09 | 操作内容: `scripts/inbox_watcher.sh`
  `_is_resolved_block()`(1930-1936行)へ「✅解決済み/✅完了」等の解決済み
  表記の検出を追加する機構修理(**本AQは起票のみ・実装はcmd_189では
  一切行っていない。フィーチャーフリーズ下ゆえ実装には別途殿の裁可を
  要する**) |
  理由: cmd_189【5・AQ起票のみ・建造禁止】(将軍下達・
  `queue/shogun_to_karo.yaml` id: cmd_189)の指示により、判定ロジック
  本体の修理はフリーズ下の機構変更にあたるため建造せず、本AQとして
  起票し殿の裁可を仰ぐ |
  doubt: 🔴**(i) 背景**: 本日2026-09-09、dashboard.md 🚨要対応欄の
  24時間放置通知が偽陽性5/5であった(`logs/ntfy.log`実記録より):
  ```
  [2026-09-09T10:41:38] OK (HTTP 200) topic=shogun_notify_... msg=🚨 24時間放置: - 🚨🚨**緊急割込・実害進行中(将軍の実地被弾・2026-08-27 23:2x)**:
  [2026-09-09T10:41:39] OK (HTTP 200) topic=shogun_notify_... msg=🚨 24時間放置: - 🔴**新規発見(subtask_181_B QC時・軍師・2026-08-27 20:36・家老
  [2026-09-09T10:41:40] OK (HTTP 200) topic=shogun_notify_... msg=🚨 24時間放置: - 📌**本日セッション開始点検スイープ結果(cmd_181受入条件G・将軍実測)**:
  [2026-09-09T10:41:40] OK (HTTP 200) topic=shogun_notify_... msg=🚨 24時間放置: - 📌**本夜の新規発見4件(cmd_180・起票せず可視化のみ・出典: `queue/shogun
  [2026-09-09T10:41:41] OK (HTTP 200) topic=shogun_notify_... msg=🚨 24時間放置: - 📌**家老の監視義務(cmd_179依頼事項3・軍師設計)**: `logs/deadman_a
  ```
  上記5件のうち3件はdashboard.md本文に既に「✅解決済み」「✅完了」と
  明記済みであり、実害ある未対応事項は0件であった(cmd_189【2・附録】
  出典)。
  **(ii) 現行判定ロジックの実態**: `scripts/inbox_watcher.sh:1930-1936`
  (`grep -n -A6 "^def _is_resolved_block" scripts/inbox_watcher.sh`で
  実測):
  ```
  1930:def _is_resolved_block(text):
  1931:    # アイテムブロックの本文本体(bullet prefixを除いた部分)が~~で始まり、
  1932:    # ブロック内(複数行可)のどこかで~~が再度出現して閉じる場合、解決済みとみなす。
  1933:    # 閉じタグが無い壊れたMarkdownは安全側(False=未解決扱い)に倒す。
  1934:    body = _strip_leading_comments(text)
  1935:    body = re.sub(r'^[\s\-\*\d\.]+', '', body, count=1)
  1936:    return body.startswith('~~') and '~~' in body[2:]
  ```
  1936行目が示す通り、解決済み判定の唯一の基準はブロック本文が取消線
  (`~~...~~`)で始まり閉じることのみであり、「✅解決済み」「✅完了」等の
  絵文字プレフィックス表記は一切判定対象に入っていない。呼出元
  `check_dashboard_staleness()`(2082-2083行付近)は
  `_is_resolved_block(block_text)`がFalseを返す全ブロックを未解決扱いで
  経過時間判定へ進める。
  **(iii) 修理案の骨子**(実装はしない・案の記述のみ):
  `_is_resolved_block()`の`return`文を、取消線判定に加えて本文が
  「✅解決済み」または「✅完了」で始まる場合もTrueを返すよう`or`条件で
  拡張する。両表記が将軍・家老いずれの運用でも実際に使われている
  (cmd_189本文中の実例: 「✅解決済み」「✅完了」)ため、片方のみを追加
  するのではなく両方を検出対象に含める。既存の取消線判定は変更せず
  維持し(cmd_157の教訓=族の一部だけを直すと再発する、を踏まえ両表記を
  同時に追加する)、閉じタグ相当の終端検出が不要な絵文字プレフィックス
  方式は「行頭一致のみ」で判定し、安全側(誤ってFalseに倒す)の設計方針
  (1933行目コメント)を踏襲する。
  **(iv) 修理せぬ場合の残存リスク**: 次に誰か(将軍・家老いずれでも)が
  「✅解決済み」または「✅完了」の表記のみ(取消線を伴わない)でdashboard
  本文に解決を記す瞬間、`_is_resolved_block()`はFalseを返し続け、本日
  同様の偽陽性(24時間放置通知の誤発火)が再発する。cmd_189本文が示す
  通り、今回の5件中3件がまさにこの形式(取消線なし・絵文字表記のみ)で
  あった。
  **(v) 🔴一次観測点**(Q42-5細則に倣う具体的観測方法): 修理後、
  scratchpad等の一時領域で合成データ(取消線を伴わず「✅解決済み」または
  「✅完了」のみで書かれたアイテムブロック、`<!-- created_at: ... -->`
  マーカーに24時間超過前の日時を付与したもの)を作成し、修理後の
  `_is_resolved_block()`にそのブロックのテキストを単体で与えて`True`
  (解決済み)を返すことを確認する。加えて`check_dashboard_staleness()`
  相当のワンショット再判定(cmd_189【1-2】で用いた手法と同一)を合成
  dashboardに対して実行し、当該合成ブロックが発火対象に含まれない
  (0件)ことを実出力で示す。既存の取消線形式の合成ブロックについても
  同様に判定が維持されること(退行なし)を併せて確認する。
  状態: approved(承認者: 殿・日付: 2026-09-09・出典: 殿の直接下命
  2026-09-09・端末上・`queue/shogun_to_karo.yaml` id: cmd_190「本下命は
  AQ-016(判定ロジック修理のフィーチャーフリーズ・カーブアウト)に対する
  殿の裁可そのものでもある」)。
  【subtask_190_C追記・2026-09-09・足軽1号】実際に実装された修理内容は
  上記doubt(iii)の骨子(取消線判定に「✅解決済み」「✅完了」の本文文言
  検出を`or`条件で追加)とは異なる。cmd_190において殿が「本文文言は
  判定に使わない」と明示的に禁じたため、実装(subtask_190_A)は本文文言
  検出方式を採らず、機械可読マーカー`<!-- resolved: true -->`への
  一本化という別方式で行われた(取消線判定は既存互換として維持)。
  詳細は`mandate/verifiers.md`「解決済みマーカー(resolved)の記法
  (cmd_190)」節・`queue/reports/ashigaru4_report.yaml`
  task_id: subtask_190_A参照。
