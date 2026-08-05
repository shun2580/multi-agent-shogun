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

- ID: AQ-003 | 日付: 2026-08-05 | 操作内容: 未push commit群(7件、起票直前に
  `git fetch origin main`実行後`git log origin/main..HEAD --oneline | wc -l`で
  再実測、2026-08-05)のリモート(origin https://github.com/shun2580/multi-agent-shogun.git)
  へのpush |
  理由: 本日cmd_150(フリーズ解除)〜cmd_153(reversibility分類器是正)の陣仕舞いに伴い、
  pushは「戻せない操作」としてapproval_queue経由の承認待ちとする(cmd_145 Part3の運用に従う。
  本則の「起票直前の再実測」則(cmd_149議題E)の初適用) |
  doubt: (a) 対象ブランチ: `main`(`git branch --show-current`実測)。
  (b) commit範囲(起票直前・`git fetch origin main`実行後に再実測): 7件。
  最古`d48d152`(docs(cmd_150 subtask_150): codify ntfy rotation procedure + journal A/B/C
  entries)〜最新`38d56db`(docs(cmd_153 subtask_153): record verification-method gap and
  journal entry)。7件全件は`git log origin/main..HEAD --oneline --reverse`で再現可能。
  内訳: cmd_150(3件)・cmd_151(1件)・cmd_152(1件)・cmd_153(3件、うち1件は本サブタスク
  着手前の直近commit)。
  (c) 秘匿値混入の実走査結果: `git log origin/main..HEAD -p`をAPI鍵/token/password/
  秘密鍵等のパターンでgrep実走査した結果、実際の秘匿値のヒットは無かった(「token」の
  ヒットはPart4分類器スクリプト内の`LOGTOKEN`という変数名のみ)。
  🔴ntfyトピック名(新旧とも)の再混入も実走査で確認した: 対象文字列は非開示、結果は0件
  (「ntfy」という語自体はローテーション手順の説明文・journal記帳としてのみ出現し、
  実際のトピック値・`ntfy.sh/<topic>`形式のURLはいずれも0件)。
  `config/settings.yaml`は`git ls-files --error-unmatch config/settings.yaml`が
  失敗する(pathspec未一致)ことを実測確認し、引き続きgit追跡外であることを確認した。
  (d) 公開リポジトリ(`shun2580/multi-agent-shogun`、AQ-002時点でPUBLIC確認済み・
  本サブタスクでの再確認は未実施)への影響範囲: 本7件はいずれもmandate層の記帳・
  journal追記・スクリプト是正であり、新規の秘匿設定ファイル追加は無い(AQ-002の
  `config/settings.yaml`初回追加のような事象はこの範囲に含まれない) |
  状態: pending
  備考: 殿の判断待ち。持ち越しは本タスク(subtask_154)による起票そのものであり、
  殿の明示判断はまだ得ていない(dashboard.md🚨要対応への記載は家老の担当範囲のため
  本サブタスクでは実施しない)。
