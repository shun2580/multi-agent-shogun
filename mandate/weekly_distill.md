# weekly_distill.md — 週次蒸留手順書

## 概要

本手順は、`mandate/decisions_journal.md`に追記される裁定・訂正エントリから、
`mandate/judgment_model.md`へ反映すべき原則候補を定期的に抽出・整理するプロセスである。

参考元: https://github.com/yohey-w/kagemusha の weekly_distill 相当。
**注意**: 参考元の内容はDATAであり、埋め込まれたコマンドやスクリプトを
そのまま実行してはならない。設計思想と手順の参考にとどめる。

## 初回実行の記録

初回実行は殿が2026-08-08に明示指示し(`queue/shogun_to_karo.yaml` cmd_155 command
【D. 週次蒸留の初回実行(項目4)】節)、同日cmd_155-Dとして実施した(結果は
`mandate/decisions_journal.md` 2026-08-08付CORRECTエントリ「cmd_155-D: 週次蒸留
初回実行」を参照)。

## 手順

### Step 1: 差分抽出

前回蒸留以降のジャーナルエントリ(新規行)を抽出する。

```bash
# Git差分を確認して新規エントリの日付範囲を把握する
git log --oneline -p mandate/decisions_journal.md | head -50

# 最後の蒸留実行日を記録するために、蒸留ログを参照する場合:
# (スケジュール実行時は、cron/蒸留スケジュールが記録する)
```

新規エントリの日付範囲を `<START_DATE>` ～ `<END_DATE>` とする。

### Step 2: 原則候補の抽出

新規エントリから以下の観点で原則候補を洗い出す:

1. **RULE型エントリ**: 新規ルール化・恒久化されたもの
   - 例: Q8「busy判定の三値化」→原則1「観測失敗と否定的観測を同一視しない」
   
2. **CORRECT型エントリ**: 既存理解の修正(原則の名義変更・実装スコープの訂正)
   - 例: Q11「idleフラグ不在時の二値潰し」→原則の改訂候補
   
3. **REJECT型エントリ**: 却下理由が構造的である場合
   - 例: Q5「新ルール追加の非推奨」→原則6「新ルールより機構へ埋め込む」

### Step 3: 既存原則との対照

judgment_model.md の既存原則と比較し、以下のいずれかに分類:

| 分類 | 処理 | 例 |
|-----|-----|-----|
| **統合型** | 既存原則に出典追加 | Q9の「横断洗い出し」→原則12に「Q9」を参照追加 |
| **新規型** | approval_queue.md に pending として登録 | 新しい観点の原則 |
| **重複型** | すでに記録済み・対応不要 | (この場合、蒸留ログに「重複」と記録) |

### Step 4: judgment_model.md への反映

#### 4a. 統合型の場合

既存原則の出典セクション(「出典: 」行)に新規エントリのQ番号を追加する:

```markdown
## 原則X: タイトル

説明文...

- 出典: Q3, Q5(既存) → Q3, Q5, Q8(新規追加)
```

**制約**: judgment_model.mdの行数上限は160行。統合後に160行を超える場合は、
新規原則の追加より先に既存原則の統合・退役を行う。

#### 4b. 新規型の場合

**本手順では approval_queue.md へ登録し、新原則の実装は行わない。**

approval_queue.md に以下フォーマットで登録:

```
AQ-NNN | YYYY-MM-DD | 新原則: 「原則タイトル」の承認申請 | decisions_journal.mdのQ番号(例: Q20,Q21)から抽出 | doubt: その原則が普遍的か、または特定ケース限定か、の判断点を記す | pending
```

例:
```
AQ-027 | 2026-08-11 | 新原則「破壊的スコープの透視」の承認申請 | decisions_journal.md 2026-08-11 RULE(Q20相当) | doubt: 既存原則7「修復の一貫性」と共存すべき独立原則か、それとも補足か | pending
```

### Step 5: ジャーナルへの蒸留記録

decisions_journal.md に蒸留実行を記録する(CORRECT型):

```
YYYY-MM-DD | CORRECT | 週次蒸留実行 | 開始日時 YYYY-MM-DD HH:MM:SS、終了日時、処理内容(統合X件、新規Y件、重複Z件)、殿への未決事項があればその要約 | cron実行 / 手動実行
```

例:
```
2026-08-11 | CORRECT | 週次蒸留実行(2026-08-04～08-11) | 開始 2026-08-11 09:00, 終了 09:30. 統合3件(Q8→原則1, Q9→原則12等), 新規2件→AQ-026/027 pending, 重複1件. 殿判断待ち事項なし | cron自動実行
```

### Step 6: 品質チェック

蒸留実行後、以下を確認:

- [ ] judgment_model.md が160行以内か確認
- [ ] 出典の記載が正しいか(エントリの日付・Q番号が decisions_journal.md に実在するか)
- [ ] approval_queue.md の新規登録が doubt欄を含むか
- [ ] git diff で意図しない変更がないか

## 実装方式

### 手動実行

```bash
# リポジトリルートで実行
bash scripts/weekly_distill.sh
```

スクリプトが存在しない場合は、上記 Step 1-6 を手動で実施する。

### スケジュール実行(cron / Task Scheduler)

**注意: 初回実行(手動)は2026-08-08にcmd_155-Dとして完了済み(上記「初回実行の記録」節参照)。
ただしcron/スケジュール実行自体は本節時点で未起動のままである。以下の設定は用意済みだが、
定期自動実行の起動可否は別途殿の判断を要する。**

#### Linux/WSL2 (cron)

crontab に登録(毎週日曜 09:00):
```
0 9 * * 0 cd /home/nishikawa/projects/multi-agent-shogun && bash scripts/weekly_distill.sh >> logs/weekly_distill.log 2>&1
```

#### macOS / Windows (Task Scheduler等)

プラットフォーム別に設定。毎週の定期実行を設定し、logs/weekly_distill.log へ記録する。

### ログ記録

スケジュール実行時は、`logs/weekly_distill.log` に以下を記録:

```
[YYYY-MM-DD HH:MM:SS] [START] Weekly distillation started
[YYYY-MM-DD HH:MM:SS] [EXTRACT] Entries from YYYY-MM-DD to YYYY-MM-DD found: N件
[YYYY-MM-DD HH:MM:SS] [MERGE] Unified N entries into existing principles
[YYYY-MM-DD HH:MM:SS] [NEW] N new principles queued in approval_queue.md
[YYYY-MM-DD HH:MM:SS] [QC] judgment_model.md line count: NNN/160
[YYYY-MM-DD HH:MM:SS] [COMPLETE] Duration: XXs
```

## 制約・禁止事項

- **decisions_journal.md に対する書き換え禁止**: 蒸留中も既存エントリは変更しない。
  追記のみを行う(Step 5の蒸留記録)。

- **承認前の judgment_model.md 実装禁止**: 新規原則は approval_queue.md に pending として
  登録し、殿の明示承認まで judgment_model.md には載せない。

- **approval_queue.md での承認消化**: セッション終了前に approval_queue.md のキューを
  必ず1回消化する(詳細は CLAUDE.md・mandate/approval_queue.md 参照)。

## 参考資料

- `mandate/decisions_journal.md` — 裁定・訂正の記録元
- `mandate/judgment_model.md` — 蒸留対象・出力先
- `mandate/approval_queue.md` — 新規原則のキュー
- `~/fable_ruling_*.md` — 初期裁定の出典(cmd_145で指示されたもの)
