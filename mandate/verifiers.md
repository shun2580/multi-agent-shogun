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

**一次観測点(Q42-5遡及適用・cmd_178)**: `logs/timing_events.jsonl`の`cmd_id`フィールドの
ユニーク件数(`grep -oE '"cmd_id": *"[^"]+"' logs/timing_events.jsonl | sort -u | wc -l`。
`scripts/analyze_timing.py --phase-breakdown`内部の`by_cmd`グルーピングと同一キー)が
約10件に達したことをもって評価条件充足とする。

## Fast-Lane実運用評価条件（cmd_192工程3・ashigaru3起票）

`instructions/karo.md`「Fast-Lane Exception」節はcmd_086 Part C制定時、「実cmd 3件の
累積をもって常用可否を評価する」という試行運用パラグラフを含んでいたが、暦日期限
のない件数条件であるにもかかわらずkaro.md本文に据え置かれ続けており、
`mandate/verifiers.md`側の条件式集約箇所（本節）へ未収容だった。cmd_192工程3で
karo.md本文から当該パラグラフを削除し、本節へ条件式として集約する
（`judgment_model.md`原則4: 交通量と無関係な代理指標=暦日期限を避ける、の適用。
「期日を持つ約束の起票禁止則」節（Q35）参照）。

**評価条件**: `scope_check_fastlane_eligible()`による機械判定でexit 0（適格）と
判定され、かつ実際にQC短縮フローが適用された実cmd事例が**3件累積**した時点で、
本運用の常用化可否を評価する。🔴**暦日期限は設けない**。

**現況（2026-09-09時点・ashigaru3実データ確認）**: `mandate/decisions_journal.md`
（`grep -n "fastlane\|Fast-Lane" mandate/decisions_journal.md`）・`dashboard.md`
（`grep -n "fast-lane.*件目\|fast-lane.*exit 0(適格)" dashboard.md`）を確認した
限り、実際に適用され「適格」と記録された実cmd事例は**cmd_096（2026-07-17、
「fast-lane検証実カウンタの記念すべき1件目」）の1件のみ**。cmd_089/091は消失
原因究明・再配線作業であり適用実績ではない。cmd_094は不適格（exit 1）判定の
ためカウント対象外。2026-08-27時点のdashboard.md記載（「タスク1(fast-lane常用
可否): 実データ0件」）とも整合する。3件未満のため、本条件式は現時点未充足。

**一次観測点**: `mandate/decisions_journal.md`と`dashboard.md`を対象に
`grep -n "fast-lane" mandate/decisions_journal.md dashboard.md`を実行し、
「実際に適格判定（exit 0）でQC短縮フローを適用した」旨が明記された実cmd事例の
ユニーク件数を数える（消失調査・再配線・不適格判定の記述は含めない）。今後
新たな適用事例が生じた際は、`mandate/decisions_journal.md`へ1行記帳することを
推奨する（記帳が無いと本節の現況調査を都度手動で再実施することになる）。

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

## 一次観測点名指し細則(Q42-5・cmd_178)

**caveat・条件式は、その解除/評価の一次観測点(ファイルパスと機械判定可能なパターン)を
名指しして書く。**

**根拠**: cmd_140のcaveat(stall検知機構の本番初発火の観測)は、条件式が観測対象の
イベント種別を名指ししていなかった。評価者(2026-08-09時点)は起動ログ
(`logs/stall_watcher.log`)を見て「イベントが無い」と判じたが、実イベント
(`event: nudge_sent`)は検知ロジック自体が書く`logs/stall_events.jsonl`に記録される
設計であり、そちらは一度も参照されなかった。結果、本番初発火(2026-08-01T00:29:50)から
約1ヶ月、事実に反する「初発火0件」がcaveatとして維持され、将軍はそれを第12報・第13報で
Fableへ誤報告した。**条件式が一次観測点(ファイルパス＋パターン)を名指ししていれば、
セッション開始点検スイープでのgrep一発により1ヶ月前に解除されていた**(出典: Fable裁定
Q42-5、`queue/shogun_to_karo.yaml` cmd_178)。

**適用**: 新設・既存を問わず、caveat・条件式には必ず以下2点を明記する。
1. 一次観測点となるファイルパス(例: `logs/stall_events.jsonl`)
2. 機械判定可能なパターン(例: `event: nudge_sent`の出現件数を数える`grep`/`jq`コマンド)

**全件遡及適用(subtask_178_B・全件洗い出し実測)**: 制定時点で存在した既存の未解除
caveat・条件式**全件**(`dashboard.md`「📋未解除caveat追跡」欄1件〈cmd_147〉、
`mandate/approval_queue.md`のpending状態3件〈AQ-008・AQ-010・AQ-012〉、本ファイル内の
条件式1件〈cmd_156 phase-breakdown評価条件、直下の「一次観測点(Q42-5遡及適用)」参照〉、
計5件)へ本細則を遡及適用し、各所在に一次観測点を追記した。対象件数・所在の洗い出し
方法(`grep -n`実行結果を含む)の全文は`queue/reports/ashigaru2_report.yaml`
task_id: subtask_178_Bを参照のこと。

## 期日を持つ約束の起票禁止則(Q35・cmd_168)

期日を持つ約束の起票を禁ずる。すべて次回セッション開始時に評価される条件式として書く
(出典: Fable裁定Q35)。

xhigh再測窓(2026-08-09〜2026-08-16、subtask_168_Bが条件式へ書換え済み)が期日形式の
否定実例である——暦日で区切った再測窓は、開いたことにも閉じたことにも誰にも気づかれない
まま16日間放置され、無効と確定した。セッション非依存の到達手段(cron等の新規常駐機構)は
Fableが明示的に不採用とした選択肢であり、駆動力はセッション開始時の条件式評価に一本化する。

**先送り表現の禁止(Q38・cmd_172)**: 「次セッション」「後で」等、セッション境界・時期に
依存する先送り表現を禁ずる。先送りには阻害条件(何が揃えば起こせるか)を必ず名指しし、
阻害条件が既に空なら直ちに起こす。

本追記は制定当日、制定者自身の裁定文へ適用され欠陥を検出した事例である——Q35を
制定したのと同じ2026-08-26、Fable裁定文自身が「次セッション最優先」というセッション
境界依存の先送り表現を含んでいたことが判明した(検出者は将軍)。「Fableが間違えた」の
ではなく、**制定当日の則が、制定者自身の文へ適用されて欠陥を検出した**という構造であり、
則が生きて働いた実例である。Q17(未確認の援用は発令側全体に及ぶ)に続く、規律が発令側にも
及ぶことの2例目である。詳細は`mandate/decisions_journal.md`該当RULEエントリ参照。

## 機構是正の同族横展開点検則(Q36・cmd_168)

「機構の是正cmdは、①同一機構内、②是正対象と同一の入力源(ファイル・
ログ)を共有する機構、③是正対象と同一の出力チャネル(ntfy等)を
共有する機構、のいずれかに該当する同族欠陥の横展開点検を受け入れ
条件に含める。②③の該当機構はgrep等で機械的に列挙し、列挙結果と
点検済み/未点検の区分を是正cmdの成果物へ含める——境界を主観的な
『似ている』でも実行不能な『全機構』でもなく**共有依存の機械列挙**で
引く。列挙可能ゆえ有界であり、機械的ゆえ漏れの検証ができる」
(出典: Fable裁定Q43、cmd_179)。

- 成功例: cmd_156(`dashboard.md:572-573`)——`--phase-breakdown`の0.0s誤表示是正の際、
  横展開点検によりescalation_sec検知ロジック未実装・rework_sec真ゼロ/計測不能混同という
  別の同族欠陥を能動的に発見・是正した。
- 失敗例: cmd_146(`dashboard.md:657`)で一度機械化した24時間放置通知が、その機械化の網の
  外側で本日(2026-08-26)偽陽性100%を発した(`memory/MEMORY.md`28行目、原因=取消線区別
  なし+section単位created_at)。cmd_146は「どの範囲を見るか」を直したが「見た範囲の中で
  何を生きた項目と見なすか」は手つかずのまま残っていた。

機械化は一度で完結せず、族の残りを掃き続ける営みである。

## 新設接続則(Q37項目10・cmd_168、Q27統合)

建てたものは、稼働・裁定・記帳の経路に接続されるまで完了ではない。台帳新設→初期投入、
flag新設→常用化AQ起票、機構新設→本番経路反映確認を建造cmdの完了条件に含める
(出典: Fable裁定Q37項目10)。

適用例:
- **台帳新設**(旧Q27則をここへ統合): 新設する台帳・追跡欄の完了条件には、制定時点で
  既に存在する対象の全件洗い出しと初期投入を含める。**線引きの根拠(Fable明示指示)**:
  頻発するランタイム状態の観測は機構(watcher・自動記録)で持つが、稀にしか起きない
  設計時点の確認(台帳新設という一回きりの瞬間)はルール(文書規律)で持つ——発火頻度に
  応じて機構とルールを使い分ける(出典: Fable裁定Q27・cmd_166。Q23で新設した
  `dashboard.md`「📋 未解除caveat追跡」欄が、新設した瞬間に既存対象を取りこぼしていた
  実例の是正として一般則化。取りこぼし件数の詳細はcmd_166当該サブタスクの完了報告・
  `mandate/decisions_journal.md`該当RULEエントリを参照)。
- **flag新設**: subtask_168_Aが新設した`dashboard_staleness.enabled`が実例である
  (flag新設→常用化AQ起票の適用対象)。
- **機構新設**: 既存のQ23型未解除caveat事例(subtask_168_Bのcmd_164)を参照する。

### 実装細則(Q44・cmd_178)

**建造サブタスクのallowed_pathsと受け入れ条件には、接続先(フック登録ファイル・設定ファイル
等)を含める。接続先が権限上付与できない場合(Tier2等)は、接続未了をdone_with_caveatで
明示し、doneと呼ぶことを禁ずる。**

出典: Fable裁定Q44(2026-08-26)。cmd_177がAQ-011 doubt(a)として発見した実例(検出と是正
権限の不一致)を教訓とする——Q33(b)ガード(`scripts/pretooluse_staged_ignore_guard.sh`)は
建造されたが、`.claude/settings.json`PreToolUse配列への接続はsubtask_171_Aの
allowed_pathsが`scripts`ディレクトリのみを含み`.claude/settings.json`を含んでいなかった
ため、同一サブタスク内で完了できなかった(「則は働いたが、権限が伴わなかった」)。

本細則は`mandate/decisions_journal.md`(2026-08-26付RULEエントリ「新設接続則の実装細則:
建造サブタスクのallowed_pathsには接続先を含めよ(cmd_177)」、`grep -n "新設接続則の実装細則"
mandate/decisions_journal.md`で確認可能)と同趣旨だが、(1)受け入れ条件への明記義務、
(2)接続先が権限上付与できない場合(Tier2等)のdone_with_caveat明示義務、の2点を追加した
正式版として本節へ制定する(重複回避の作法はQ27統合時と同じ)。journal側のエントリは
履歴記録としてそのまま残し、変更しない。本節が正式版であり、journal記帳と併記させない
(`grep -n "接続先" mandate/verifiers.md`で本節1箇所のみに存在することを確認済み)。

## 持ち越しマーカー(carryover_approved)の記法(cmd_170)

殿の明示許可による持ち越し項目を、24時間放置通知(`scripts/inbox_watcher.sh`
`check_dashboard_staleness()`)の検出対象から除外するための機械可読マーカー。

**記法**: `dashboard.md`の各項目ブロックにおいて、`created_at`コメントの
**直後**(1行空けず)に以下を置く。

```
<!-- created_at: YYYY-MM-DDTHH:MM:SS -->
<!-- carryover_approved: true -->
- **項目本文...**
```

**用途**: `created_at`が古くても、殿が明示的に「持ち越してよい」と判断した項目は
「放置」ではなく「管理された保留」である。両者を機械が区別できねば、正しい運用が
警報を鳴らし続ける(是正の背景はcmd_170 north_star参照)。検出ロジックは
`_carryover_re = re.compile(r'^\s*<!--\s*carryover_approved:\s*true\s*-->', re.IGNORECASE)`
でブロック先頭(`created_at`直後)にのみ照合し、マッチすればhours超過であっても
通知対象から除外(`continue`)する(`scripts/inbox_watcher.sh`
`check_dashboard_staleness()`、subtask_170_A実装)。

**実使用例**(`dashboard.md`、subtask_170_Aが実際に付与した箇所。
`grep -n "carryover_approved" -B2 dashboard.md`で確認可能):

```
192:  <!-- created_at: 2026-08-10T00:34:36 -->
193:  <!-- carryover_approved: true -->
194:  🚨**別件・新規未push分がpending持ち越し中**: AQ-005本来のpush後、
```
(AQ-005新規未push分。殿の明示許可による持ち越し、cmd_167acceptance_criteria)

```
200:<!-- created_at: 2026-08-10T00:45:00 -->
201:<!-- carryover_approved: true -->
202:- **AQ-008: backup branch削除可否**: pendingのまま。殿の明示許可により
```
(AQ-008。殿の明示許可による持ち越し、cmd_167)

対照として、AQ-004・AQ-007は同じく殿裁定待ちの項目だが`carryover_approved`が
**意図的に付与されていない**(=通常の放置検出対象のまま)。マーカーの
「あり/なし」両パターンが本番データに実在する(dashboard.md 205行目・209行目、
`created_at`のみでcarryover_approvedコメントなし)。

## 解決済みマーカー(resolved)の記法(cmd_190)

殿の明示禁止により、🚨要対応欄の解決済み判定は本文文言(「✅解決済み」「✅完了」等の
自然言語記号)へ依存させてはならない。判定根拠を機械可読なHTMLコメントマーカーへ
一本化する(north_star: 「✅解決済み」も「取消線」も人が書く記号であり、書き方は
増え続ける。増え続ける記号を追いかける限り、我らは永遠に3例目・4例目を迎える)。

**記法**: `dashboard.md`の各項目ブロックにおいて、`created_at`コメントの
**直後**(1行空けず、carryover_approvedと同じ位置)に以下を置く。

```
<!-- created_at: YYYY-MM-DDTHH:MM:SS -->
<!-- resolved: true -->
- **項目本文...**
```

**判定ロジック**: `_is_resolved_block()`(`scripts/inbox_watcher.sh`、
`_DASHBOARD_RESOLVED_BLOCK_PY`として一元化され`check_dashboard_staleness()`と
`build_fleet_idle_message()`の両方から呼出・cmd_190 subtask_190_A実装)は、
以下いずれかで解決済みと判定する:
  (a) ブロック先頭の連続するHTMLコメント群内(`created_at`直後、
      `carryover_approved`と同じ領域)に`<!-- resolved: true -->`がある
  (b) 取消線(`~~...~~`、既存互換・削除禁止)で本文本体が囲まれている
🔴本文文言(「✅解決済み」「✅完了」等)は判定に一切使わない
(殿の明示禁止・cmd_190「自然言語記号を判定対象に増やすこと自体が禁止事項」)。

**carryover_approvedとの使い分け**:
  - `resolved: true` = 該当項目そのものが解決済みであり、もはや放置ではない
  - `carryover_approved: true` = 未解決だが殿の裁可により意図的に持ち越し中
    (放置ではないが、解決もしていない)
両者は意味的に排他——ある項目が解決済みであれば持ち越しマーカーは不要である。

**取消線との関係**: 取消線([[carryover_approved]]の節にある既存互換パターン
とは別に)引き続きサポートされ、削除は禁止(殿の明示禁止・既存6件の互換維持)。
ただし**新規項目では取消線でなく`resolved`マーカーを用いること**——
判定根拠を自然言語記号から機械可読マーカーへ移す、というのが本節新設の
理由そのものである。

## 秘匿値記述禁止則(cmd_180)

「**秘匿値(トピック名・鍵・トークン等)は記帳・報告の本文へ平文で書かず、参照名(設定キー名)で書く。
値そのものが必要な場合は設定ファイル(untracked)のみに置く**」
(出典: 殿の直接下命、`queue/shogun_to_karo.yaml` cmd_180 acceptance_criteria
【工程3・一般則の制定】項、2026-08-26。契機は`mandate/decisions_journal.md`
2026-08-09付エントリへのntfy_topic平文混入が17日間PUBLICリポジトリ上に露出した
インシデント——詳細は同ファイルの該当CORRECTエントリ〈cmd_180〉参照)。

**根本原因の構造**: `memory/MEMORY.md`では既にこの規律が守られていた(同ファイル
145行目・296行目、いずれも「🔴秘匿値〈ntfy_topic等〉はここに転記していない」と
明記)一方、`mandate/decisions_journal.md`にはこの規律が及んでいなかった——
同ファイルの2026-08-09付CORRECTエントリ(cmd_158 caveat解除の独立再確認、
subtask_160_C記帳)が`logs/ntfy.log`引用文中のtopic=部分にntfy_topic値を
平文のまま書き写し、それが2026-08-09 21:57のpushで公開された。**規律は
存在したが、一部の台帳にしか及んでいなかった**構造であり、本則はこの
構造的欠陥を記帳・報告のあらゆる経路へ一般化して塞ぐものである。

**適用対象**: `mandate/*.md`各台帳・`dashboard.md`・`queue/reports/*`・
`queue/inbox/*`・tracked配下の`logs/`等、秘匿値を書き得る全ての記帳・報告経路。
cmd_180工程3(横展開点検)による機械列挙・点検結果(点検済み/未点検の区分)は
`queue/reports/ashigaru2_report.yaml` task_id: subtask_180_B参照。

## 機械判定は自然言語記号に依存しない(Q47)

条文(Fable裁定Q47・原本逐語、`~/fable_ruling_20260909_q46q49.md`39-41行目):

「機構が状態判定に用いる標識は、その機構が仕様として定義した機械可読マーカー
（HTMLコメント等）に限る。本文の文言・絵文字・取消線その他の人間向け表記を
判定条件に含めない。マーカーの仕様は機構側の正典文書に記載する。」

射程はQ43(共有依存の機械列挙、[[機構是正の同族横展開点検則(Q36・cmd_168)]]参照)と
同型(出典: Fable裁定Q47冒頭)。

**取消線既存互換は本則の例外**([[解決済みマーカー(resolved)の記法(cmd_190)]]参照)——
二流儀併存はQ36が戒めた構造ゆえ、下記条件式(a)でQ35(期日を持つ約束の起票禁止則)に
基づき撤去を予約する。

**既存の本文文言依存の是正優先度(Q47付帯・殿の明示線引き)**: 本文文言依存の是正は、
**殿への通知を駆動するもの**(fail-loudの土台を崩す偽陽性通知)**に限る**。それ以外の
本文文言依存箇所は`queue/shogun_to_karo.yaml` cmd_190依頼事項3の一覧(Q36同族横展開点検・
is-scope調査結果、`queue/reports/ashigaru5_report.yaml` task_id: subtask_190_B参照)に
載せたまま据え置く——🔴**是正着手を禁ずる**(殿への通知を駆動しない本文文言依存箇所には
手を出すな。出典: Fable裁定Q47、`~/fable_ruling_20260909_q46q49.md`47-49行目)。

### 条件式(a): 取消線判定の撤去条件(Q47付帯・Q35準拠)

「resolvedマーカー未付与の取消線項目が0件になった時点で取消線判定を撤去する」
(出典: Fable裁定Q47付帯)。

**一次観測点**: `dashboard.md`。
1. `grep -n '~~' dashboard.md` で取消線(`~~...~~`)を含む行を全列挙する。
2. 列挙した各取消線ブロックについて、ブロック先頭(`created_at`コメント直後、
   [[持ち越しマーカー(carryover_approved)の記法(cmd_170)]]・
   [[解決済みマーカー(resolved)の記法(cmd_190)]]と同じ位置)を
   `grep -B5 <該当行番号> dashboard.md`等で確認し、`<!-- resolved: true -->`
   マーカーが併記されているか判定する。
3. マーカー未付与の取消線ブロック件数を数える。0件になった時点で本条件式充足——
   `scripts/inbox_watcher.sh`の`_is_resolved_block()`(1935行目定義)から取消線分岐
   `return body.startswith('~~') and '~~' in body[2:]`(1947行目)を撤去し、
   本ファイル「解決済みマーカー(resolved)の記法(cmd_190)」節の「取消線との関係」
   段落も合わせて更新する。

**現況(2026-09-09時点・工程6着手時点の粗観測)**: `grep -c '~~' dashboard.md`は
複数行ヒットあり、`grep -n "resolved: true" dashboard.md`のヒット数より多い
(未精査・本条件式は未充足)。セッション開始点検スイープでの精査手順は上記1-3を
用いる。

## 人の独立検証への依存・単一障害点の再評価条件(Q48)

Fable裁定Q48: `scope_check.sh`のPreToolUse observe接続を最小の一手として実施
(Q30(b)接続則の未充足是正であり新機構の建造ではない)。原則9・フリーズは維持
(出典: Fable裁定Q48、`~/fable_ruling_20260909_q46q49.md`53-66行目)。

### 条件式(b): 軍師検分すり抜け事故の再評価条件(Q48)

「軍師の検分をすり抜けた事故が1件でも観測されたら本裁定(scope_check.sh PreToolUse
接続に関するQ48裁定)を再評価する」——単一障害点の破れは1回目が実害ゆえ3例目を
待たない(出典: Fable裁定Q48、`~/fable_ruling_20260909_q46q49.md`65-66行目)。

**一次観測点**: `mandate/decisions_journal.md`のINCIDENTエントリ。
`grep -n "軍師の検分をすり抜け" mandate/decisions_journal.md`を実行し、ヒットが
1件でもあれば本条件式充足——Q48裁定(scope_check.sh PreToolUse接続)を再評価する。
🔴今後、軍師QCが見逃した(PASS判定を出したが後に別経路で欠陥が発覚した)事故を
`mandate/decisions_journal.md`へINCIDENT記帳する際は、検出規則の機械化のため
「軍師の検分をすり抜け」という定型句を必ず含めること([[原則引用回数の検出規則（cmd_155）]]
と同型のリテラル文字列一致設計——文脈判定は行わず、記帳側が定型句を含める運用で
機械化する)。

**現況(2026-09-09時点)**: 上記grepの実行結果はヒット0件(未充足)。2026-08-27付
INCIDENTエントリ(cmd_186)は軍師が捏造を「捕らえた」成功事例であり、本条件式が
指す「すり抜けた」事故とは逆の性質のため該当しない。

## scope_checkフック(pretooluse_scope_check.sh)のenforce移行条件(cmd_192工程5)

`scripts/pretooluse_scope_check.sh`(cmd_192工程5新設、既定observe)の
enforce移行は、以下4条件(Q6出典: `~/fable_ruling_20260727_q1q4.md`
——yaml_guard_enabledのenforce移行時と同型)を**すべて**満たした時点で
候補となる。🔴暦日期限は設けない(判断は将軍が別途行う)。

1. 対象評価20件以上
2. 稼働セッション2回以上に跨る
3. 偽WOULD-DENYゼロ(allowed_paths内のはずのfile_pathが誤ってWOULD-DENYされた事例が無い)
4. fail-open(FAIL-OPEN相当のクラッシュ・判定不能)ゼロ、またはfail-open発生時は全件原因説明済み

**一次観測点(Q42-5細則)**: `logs/pretooluse_scope_check.log`を対象に
以下を実行する。
- 評価総数(条件1): `grep -cE "^\[.*\] (ALLOW|WOULD-DENY|DENY) " logs/pretooluse_scope_check.log`
- セッション跨り(条件2): `grep -oE "session=[^ ]+" logs/pretooluse_scope_check.log | sort -u | wc -l`
  (`session_id`が実際に複数稼働セッションに跨ることをdashboard.md等で追認する)
- 偽WOULD-DENY(条件3): `grep "WOULD-DENY" logs/pretooluse_scope_check.log`の
  各行についてfile_pathが実際に該当agentのallowed_paths外だったかを個別確認し、
  誤判定(allowed_paths内なのにWOULD-DENYされた事例)が0件であることを示す
  (機械集計不能・目視確認が必要な項目である旨も明記する)。
- fail-open(条件4): 本フックはFAIL-OPENタグを出力しない設計(JSON解析失敗・
  agent_id/TASK_YAML解決不能はすべて無ログexit 0のため)。よって本条件式は
  「クラッシュ・異常終了(exit code非0)がpretooluse hookの実行ログ
  (Claude Code側のhook実行エラー通知等)に記録されていないこと」を別途
  確認する形になる——本フック固有の観測点は無いため、この点に留意する。

セッション開始点検スイープ(a)条件式の評価対象として、次回セッション開始時から
評価対象に加わる(出典: `queue/reports/ashigaru5_report.yaml` task_id:
subtask_192_5、家老が反映)。

## 完了ゲート(stop_hook_evidence.sh)のenforce移行条件(cmd_192工程8)

`scripts/stop_hook_evidence.sh`(cmd_192工程8新設、既定observe、対象は
足軽・軍師・家老・将軍は対象外)のenforce移行は、以下4条件(Q6出典:
`~/fable_ruling_20260727_q1q4.md`——yaml_guard_enabled・scope_check_hook_enabled
のenforce移行時と同型)を**すべて**満たした時点で候補となる。🔴暦日期限は
設けない(判断は将軍が別途行う)。

1. 対象評価20件以上
2. 稼働セッション2回以上に跨る
3. 偽WOULD-BLOCKゼロ((a)〜(d)いずれかの条件式が、実際には充足している
   report(evidence記載済み・commit実在・SKIP0件)を誤ってWOULD-BLOCK
   判定した事例が無い——(b)の`*_evidence`末尾一致検出・(c)の commit
   ハッシュ抽出・(d)のSKIP非ゼロ検出、いずれも正規表現ヒューリスティックで
   あり誤検知の可能性が構造的に残ることに留意)
4. fail-open(FAIL-OPEN相当のクラッシュ・判定不能)ゼロ、またはfail-open
   発生時は全件原因説明済み

**一次観測点(Q42-5細則)**: `logs/stop_hook_evidence.log`および
`logs/stop_hook_evidence_blocks/`を対象に以下を実行する。
- 評価総数(条件1): `grep -cE "^\[.*\] (ALLOW-STOP|WOULD-BLOCK|BLOCK) " logs/stop_hook_evidence.log`
- セッション跨り(条件2): 本フックはStop hook起動ごとに固有session_idを
  ログへ含めない設計(stdinのsession_idはStop hook入力に含まれない場合が
  あるため未実装)。dashboard.md・queue/reports/の当該agentタイムスタンプ
  跨りで代替確認する(機械集計不能・目視確認が必要な項目である旨も明記する)。
- 偽WOULD-BLOCK(条件3): `grep "WOULD-BLOCK" logs/stop_hook_evidence.log`の
  各行についてreason=(a)〜(d)を特定し、該当report YAMLエントリを実際に
  参照して充足済みだったか個別確認する(機械集計不能・目視確認が必要)。
- fail-open(条件4): 本フックは判定不能時すべて無ログexit 0(fail-safe)で
  通す設計。よって本条件式は「クラッシュ・異常終了(exit code非0)が
  Stop hookの実行ログ(Claude Code側のhook実行エラー通知等)に記録されて
  いないこと」を別途確認する形になる——本フック固有の観測点は無いため、
  この点に留意する。

🔴**併せて、工程8-2(6回連続block通知)がenforce運用下で誤発火しないことも
確認する**: `logs/stop_hook_evidence_blocks/*.count`が実際の連続block回数
(karo・軍師の目視確認)と一致していること。

セッション開始点検スイープ(a)条件式の評価対象として、次回セッション開始時から
評価対象に加わる(出典: `queue/reports/ashigaru3_report.yaml` task_id:
subtask_192_8、家老が反映)。
