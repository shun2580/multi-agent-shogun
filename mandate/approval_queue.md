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
