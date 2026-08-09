# verifiers.md — 検証リスト(機械検証基準)

**本ファイルの位置づけ**: 既存QC基準(gunshi.md Step D等)・YAML形式要件(inbox書式等)・
既知の機械的ミス防止則を明文化して集約する。

**運用規則(CRITICAL)**: 却下理由が機械的なもの(形式違反・数値未検証等)だった場合は、
原則化(judgment_model.mdへの一般化原則追加)ではなく、まずここに1行追加すること。
機械的ミスは「一般化すべき判断原則」ではなく「毎回チェックすればよい具体項目」であり、
両者を混同しない(cmd_145 Part2③の趣旨)。

---

## 本サブタスク時点の状態

本ファイルは cmd_145 Part2a の範囲(mandate/4ファイルの新規設置)として、
骨格(本ヘッダー・運用ルール)のみを整えたものである。既存QC基準・YAML形式要件の
具体的な集約は後続サブタスク(instructions統合と合わせて実施)で行う。

## 検証項目テンプレート(記入形式)

今後、機械的な却下理由が発生した場合、以下の形式で1行追加する:

```
- [YYYY-MM-DD] 項目: <何を検証するか> / 検証方法: <grep・実行コマンド等> / 出典: <却下時のcmd_id・報告>
```

## 既知の機械的ミス防止則(初期設置時点で判明済みのもの)

- SKIP=FAIL: テスト報告でSKIP数が1以上なら「テスト未完了」扱いとする(CLAUDE.md Test Rules準拠)
- File Operation Rule: Read前提のWrite/Editを行わない(Read-before-Editの徹底)
- YAML形式: 正規報告書ファイル(ashigaru{N}_report.yaml・gunshi_report.yaml)はマルチドキュメント
  形式であり、単一ドキュメント前提のパーサで扱わない(出典: scripts/pretooluse_yaml_guard.sh の
  safe_load_all設計、cmd_120関連。gunshi_qc_145_part2aで誤引用(Q1=cmd_111 fail-loud化の話で
  無関係)と指摘され是正)
- Fable裁定の出典探索範囲: `~/fable_*.md`(裁定書ファイル)だけでなく`queue/inbox/shogun.yaml`
  (Fableがinbox経由で直接書き込んだ裁定)も必ず探索範囲に含めること(出典: cmd_145 Part2、Q18裁定
  原本が裁定書6本ではなく`queue/inbox/shogun.yaml` msg_20260729_fable_q18_enforceに存在していた
  実例。探索範囲を裁定書6本に限定した結果Q18裁定を一時的に見落とした)
- 新規feature flagを伴う機構は、flagが`config/settings.yaml`に実在し、かつ本番経路
  (`.claude/settings.json`経由の実PreToolUse呼出し等、試験用設定・試験用ログ差し替えでは
  ない実配線)で実ログ・実挙動が出ることまで確認する。コードとテストの緑だけでは未達とする
  (出典: cmd_145 Part4是正。`pretooluse_reversibility_check.sh`実装・隔離試験は緑だったが、
  `reversibility_check_enabled`が`config/settings.yaml`に一度も追加されておらず本番では
  fail-safeで常時off・実ログ0行のまま完了報告されていた実例。将軍の実機検証2026-08-04で発覚)
- done判定時は、成果物ファイルが実際にcommitされていることを`git status --porcelain`等で
  確認する。commitし忘れたまま「完了」と判定しない(出典: cmd_146成果物が一部未commitのまま
  done判定されていた実例、cmd_147是正)
- approval_queueエントリを殿の消化に出す直前、doubt欄の数値・件数を再実測して更新する
  (出典: 殿の2026-08-05裁定・cmd_149。AQ-001 doubt(a)137→149行、AQ-002 doubt(b)
  commit件数62→65件と複数回陳腐化した実例を族と認定)
- 既存ログの再スキャンで危険な形の混入がゼロだったことは、分類器が
  敵対的入力に対して安全であることを示さない。標本に無いことと
  有り得ないことは別物である(cmd_153・judgment_model原則1の適用例。
  改行区切り複合・コマンド置換を見逃していた分類器がcmd_152のQCと
  194件再スキャンをいずれも通過した実例)。
- 新設する台帳・追跡欄の完了条件には、制定時点で既に存在する対象の全件洗い出しと
  初期投入を含める。**線引きの根拠(Fable明示指示)**: 頻発するランタイム状態の観測は
  機構(watcher・自動記録)で持つが、稀にしか起きない設計時点の確認(台帳新設という
  一回きりの瞬間)はルール(文書規律)で持つ——発火頻度に応じて機構とルールを
  使い分ける(出典: Fable裁定Q27・cmd_166。Q23で新設した`dashboard.md`「📋 未解除
  caveat追跡」欄が、新設した瞬間に既存対象を取りこぼしていた実例の是正として
  一般則化。取りこぼし件数の詳細はcmd_166当該サブタスクの完了報告・
  `mandate/decisions_journal.md`該当RULEエントリを参照)。

## 原則引用回数の検出規則（cmd_155）

**検出規則**: `judgment_model.md`の原則が明示的に引用された回数は、リテラル文字列パターン
`原則\d+`（例:「原則1」「原則12」）への正規表現一致件数として数える（`grep -oE '原則[0-9]+' <file> | wc -l`）。

**走査対象ファイル群**:
- `queue/shogun_to_karo.yaml`
- `queue/reports/ashigaru*_report.yaml`（全足軽分の合算）
- `queue/reports/gunshi_report.yaml`
- `mandate/decisions_journal.md`
- `mandate/approval_queue.md`
- `dashboard.md`

**実測値（2026-08-08時点・subtask_155_AB2完了直前に最終再実測。旧値49はashigaru1の
自己言及インフレを見落としていた誤りだったため訂正した。詳細は
`queue/reports/ashigaru1_report.yaml` task_id: subtask_155_AB2を参照）**:

| ファイル | 件数 |
|---|---|
| queue/shogun_to_karo.yaml | 20 |
| queue/reports/ashigaru*_report.yaml（合算） | 34（ashigaru1=26・ashigaru2=8・ashigaru3〜7=0） |
| queue/reports/gunshi_report.yaml | 7 |
| mandate/decisions_journal.md | 5 |
| mandate/approval_queue.md | 1 |
| dashboard.md | 1 |
| **合計** | **68** |

**自己言及による水増しの既知の限界**: 本節・decisions_journal.mdの本cmd自身のRULEエントリが
検出規則を説明する際に`原則1`・`原則12`を**パターンの例示文字列**として含んでいるため、これらは
実際の判断引用ではないが正規表現一致としてカウントされる（本走査対象6ファイル中では
decisions_journal.mdの1行に自己言及3件が含まれる。他ファイルは対象外のため影響なし）。
検出規則はリテラル文字列一致という単純な設計であり、文脈判定（実引用か例示かの区別）は
行わない。数字を良く見せるための除外はしていない——むしろ限界を明示する。

**この限界はdecisions_journal.mdに固有の現象ではない（cmd_155-AB2是正）**: 判断引用の
検出規則そのものを説明・分析する文書は、書き終えた時点で自分自身の被引用数が測定時点より
増加する。これは`queue/reports/ashigaru*_report.yaml`群・`queue/reports/gunshi_report.yaml`にも
等しく起こりうる（判断引用の集計や品質チェック結果を報告本文中で論じるため）。実例:
subtask_155_ABの完了報告（`ashigaru1_report.yaml`）はA-4実測値としてashigaru1自身=9件と
記載したが、`gunshi_qc_155_AB`が同一grepコマンドを独立再実行したところ実際には18件だった
（報告書執筆によって`judgment_model`原則1・原則12への言及が増えたため）。さらにその
QC結果自身（`gunshi_report.yaml` task_id: gunshi_qc_155_AB、issue説明文中に「原則1・原則12」の
言及を含む）が`gunshi_report.yaml`の被引用数を5→7へ押し上げた（cmd_155-AB2是正時点で
確認）。したがって、この検出規則を扱う6走査対象ファイルはいずれも自己言及インフレの
対象になりうると理解し、**運用ルールの記帳・QC結果・完了報告いずれも、確定後の状態で
最終再実測してから数値を報告すること**（測定した時点の値をそのまま報告に転記すると、
報告本文の追記自体によって直後に陳腐化する）。

月次集計は`scripts/analyze_timing.py --lord-judgments`（殿の判断回数）とは別軸であり、
本節の`grep -oE`手順は原則引用回数専用（既存の月次集計コマンドに統合していない。理由:
原則引用はtiming_eventsに記録されるイベントではなく、既存文書への静的走査でのみ検出可能）。

## 工程別内訳（phase-breakdown）の評価条件（cmd_156）

`scripts/analyze_timing.py --phase-breakdown`(裁定待ち/QC往復/実行の工程別時間内訳、
検出規則・境界定義は本ファイル「原則引用回数の検出規則」節に隣接するcmd_155該当RULE
エントリ〔`mandate/decisions_journal.md`〕を参照)の評価は、**「約10cmd分のデータ
蓄積」という件数条件**を満たした時点で行う。🔴**暦日期限は設けない**
(`judgment_model.md`原則4: 交通量と無関係な代理指標を避ける、の適用)。個別cmdごとの
工程内訳報告は不要——評価はデータが十分溜まってからまとめて行う(出典: 殿の
2026-08-08裁定・cmd_156。個別cmd報告不要の反映先は`instructions/karo.md`「省力化3点
セット運用」節)。

**初期サンプル(cmd_155実測値・消去禁止)**:

| 工程 | 実測値 |
|---|---|
| 裁定待ち | 463s |
| 実行 | 241s |
| QC往復 | 958s |

出典: `queue/shogun_to_karo.yaml` cmd_155 acceptance_criteria、`scripts/analyze_timing.py
--phase-breakdown`実測(cmd_155時点)。件数条件(約10cmd分)を満たすまでは本値を初期
サンプル1件として保持する。

## ntfyトピックローテーション完全手順（cmd_150）

**選定理由**: 本ファイル冒頭の運用規則（機械的な手順は判断原則ではなく具体項目として
ここに集約する）に従い、既存の「既知の機械的ミス防止則」節と同種の性質（毎回同じ順序で
踏むべき具体手順）を持つため、他の手順書を新設せず本ファイルへ集約した。**分散させず
この1箇所にのみ記載する。**

ntfyトピック名（殿への通知購読先）をローテーションする際は、以下の6段階を**この順序で**
実施する（出典: 殿の2026-08-05裁定・cmd_150）:

1. **①新名生成**: 旧名と推測可能な関係を持たない新トピック名を生成する
   （例: `shogun_notify_` + ランダム英数12桁）。
2. **②git管理外での伝達**: 新トピック名は git 管理外の経路（例: `~/` 直下・
   パーミッション600のファイル）でのみ殿へ伝達する。git管理下のいかなるファイル
   （inbox・dashboard・decisions_journal・報告YAML・タスクYAML・commitメッセージを
   含む）にも新トピック名を平文で書かない。伝達完了後は `git grep <新トピック名>` を
   実走し、ヒットがゼロであることを実測で確認する。
3. **③殿の購読替え**: 殿が新トピックへ購読を切り替える。
4. **④到達確認**: 新トピックで実際に通知が届くことを実テストで確認する。届かない
   場合、`ntfy_listener.sh` 等の稼働プロセスが旧トピックをメモリに保持したままに
   なっていないか確認する（cmd_145 Part4「検証済みコードが稼働プロセスへ未到達」族と
   同型の穴）。
5. **⑤旧購読解除（必須）**: 殿が旧トピックの購読を解除する。**理由**: 旧トピック名は
   git履歴に残ったままpushで公開されるため、購読を解除せず放置すると第三者が
   旧トピックへ偽の通知を投げ込むことができ、殿がそれを我が陣の正規の報告と
   誤認しかねない。**購読を解除して初めて、旧トピック名は死値となる。**
6. **⑥push**: ⑤（旧購読解除）完了後にpushする。①〜⑤より前にpushすると、
   git履歴に残る旧トピック名がまだ「生きた秘匿値」の状態で公開されてしまう。

**cmd_149での欠陥（将軍の自己申告・decisions_journal.md該当CORRECTエントリ参照）**:
cmd_149で将軍が設計・実施した手順には⑤（旧購読解除）の指定が欠けていた。本手順は
その是正としてcmd_150で成文化した完全版である。
