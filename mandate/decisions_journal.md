# decisions_journal.md — 却下・訂正・裁定の追記専用ジャーナル

**過去エントリの書き換え禁止。** 本ファイルは追記のみを許可する。誤記に気づいた場合も
既存行は変更せず、新規行に「訂正」として追記すること。

**列の定義**:

| 列 | 内容 |
|---|---|
| 日付 | 裁定・発言が発された日(YYYY-MM-DD、判明していれば時刻も) |
| 種別 | RULE(規則制定) / REJECT(却下) / CORRECT(訂正) |
| 対象 | 何についての裁定か |
| 殿の発言(原文ママ) | 一次資料からの逐語引用。要約・言い換えは禁止 |
| 備考 | 出典ファイル名・補足 |
| 推定理由(任意) | その裁定・訂正が下された背景についての仮説。断定と混同させないため、記入する場合は必ず`[仮説]`を接頭辞として付けること |
| 当否が決まる条件(任意) | 上記「推定理由」が正しかったか誤りだったかを、将来どの観測(ログ・実測・再発の有無等)で判定できるかを書く欄 |

**列2件(推定理由・当否が決まる条件)の運用規則**: 両方とも任意。両方書ける場合のみ埋め、
既存5フィールド(`日付 | 種別 | 対象 | 殿の発言 | 備考`)の後ろに7フィールド行として追加する。
書けない場合は2列とも省略し従来どおり5フィールドのまま記帳せよ(片方だけ埋める運用は禁止。
既存エントリへの遡及追記も不要)。

**殿の判断回数の計測(cmd_155)**: 種別`RULE`または`REJECT`のエントリを本ファイルへ追記する際は、
その場で必ず以下を実行せよ(既存の`scripts/log_timing_event.sh`の拡張・新規計測機構は不要):

```
bash scripts/log_timing_event.sh lord_judgment_recorded <cmd_id> "" <agent> \
  --source=<agent> --extra=journal_rule:<一行要約>
```

REJECT型の場合は`--extra=journal_reject:<一行要約>`とする。CORRECT型エントリ(殿の裁定を
伴わない自己訂正)はこのトリガーの対象外とする(殿の判断回数を水増ししないため)。検出規則・
工程定義の全体像は`mandate/verifiers.md`を参照。

**🔴初期データに関する注記**: 以下のQ1〜Q19は cmd_145 の指示に基づき、Fable(claude.ai側Claude)
の裁定書から転記した初期データである。「殿の発言」欄はいずれも**Fableの裁定文からの逐語引用**
であり、殿本人の発言ではない。Fableは殿より裁定権限を委任された対外の裁定者であり、本システムに
おいて将軍からの照会に対し拘束力のある裁定を下す立場にある(出典: `~/fable_ruling_*.md` 各文書の
「発行: Fable（claude.ai側Claude）」「宛先: 将軍」の体裁)。将来のエントリでは殿本人の発言を
本欄に記録する。

---

2026-07-27 | CORRECT | cmd_111 fail-loud化(slim_yaml.py)の副作用有無 | 将軍の懸念は両方とも実コードで否定される。Fast-Lane消失との関連も無い。 | 出典: `~/fable_ruling_20260727_q1q4.md` Q1

2026-07-27 | RULE | yaml_guard書込ガード再有効化の判定基準 | 「実報告書群での偽陽性ゼロ実証」だけでは足りない。静的コーパスは過去の形式しか代表しない。 | 出典: `~/fable_ruling_20260727_q1q4.md` Q2。再有効化バー5項目(safe_load_all全面切替/静的コーパス検証/cmd_113未消化受入条件完済/欠陥2完了/observeモード新設・段階投入)を設定

2026-07-27 | RULE | settings.jsonのフック登録方式 | 今回の違反は「登録したこと」ではなく「flag=trueのまま登録・commitしたこと」にある。ルールの牙は「デフォルトoff」の側にある。 | 出典: `~/fable_ruling_20260727_q1q4.md` Q3。案イ(登録残置・flag制御)を裁定、新規flag導入時はQCでデフォルトoff確認を受入条件化

2026-07-27 | RULE | ashigaru2_report.yaml ANSI混入の修復方針 | 採用: 制御文字（ANSIエスケープシーケンス）の除去のみ。内容・構造は一切変えない | 出典: `~/fable_ruling_20260727_q1q4.md` Q4。ガード側でANSI許容する案は不採用、タイムスタンプ付きバックアップ必須

2026-07-27 | REJECT | 生端末出力貼付の上流対策(新ルール・共通経路サニタイズ) | 新ルール追加も共通経路サニタイズも不採用。既に建造中のガードが上流対策そのものである | 出典: `~/fable_ruling_20260727_q5.md` Q5

2026-07-27 | RULE | observe段階のデータ蓄積条件(yaml_guard enforce移行) | 件数主・セッション従に改定する。暦日は廃止 | 出典: `~/fable_ruling_20260727_q6q7.md` Q6。対象評価20件以上(主)・稼働セッション2回以上(従)・偽would-denyゼロ・fail-open説明済み

2026-07-27 | RULE | Part1-A死因判定(旧ロスターwatcher停止)の確定表記 | (i)確定を維持。格下げは不採用。ただし「確定の種類」を1文で併記せよ | 出典: `~/fable_ruling_20260727_q6q7.md` Q7

2026-07-28 | RULE | busy判定の三値化 | 承認。ただし「配達側に倒す」のは非破壊的動作に限定せよ | 出典: `~/fable_ruling_20260728_q8q10.md` Q8。unknown時の既定動作は破壊性で分岐(nudge=実行/`/clear`=保留)

2026-07-28 | RULE | 「観測失敗と否定的観測の同一視」族への対処 | 横断洗い出しを承認。ただし裁くのは「潰し」でなく「潰した値が駆動する動作」 | 出典: `~/fable_ruling_20260728_q8q10.md` Q9。読取専用・分類表のみ、42件全部の三値化は求めない

2026-07-28 | RULE | 下命ペースの歯止め(cmd発行) | (c)を基本に、例外は「記録義務つき」で設ける。加えてFable側も規律を負う | 出典: `~/fable_ruling_20260728_q8q10.md` Q10。dispatch済み作業の割込・組み替えを伴うcmdは既定「順番待ち」、緊急例外は記録義務+即時ntfy

2026-07-29 | CORRECT | idleフラグ不在時の二値潰し(フラグ経路の三値化) | Part Bの判定を採る。ただし実装は「三値化」ではなく「経路の縦続」で行え | 出典: `~/fable_ruling_20260729_q11q14.md` Q11。フラグ不在=判定未了としpane解析経路へ縦続

2026-07-29 | RULE | stale busy recovery発火の観測指標正規化 | 承認。ただし解釈順序を裁定として固定する | 出典: `~/fable_ruling_20260729_q11q14.md` Q12。指標=発火回数÷busy判定実施回数

2026-07-29 | CORRECT | 軍師QCチェックリストの射程(diffのみ→意図ベース) | 2行の改訂で足りる。文面の欠陥は私の起草に由来する | 出典: `~/fable_ruling_20260729_q11q14.md` Q13。意図ベースQC拡張+Part間突合の職掌化

2026-07-29 | RULE | inbox_watcher.sh是正の着手順 | 第2位を先行、ただし同一ファイルにつき並行は禁止 | 出典: `~/fable_ruling_20260729_q11q14.md` Q14

2026-07-29 | RULE | watcher9体再起動の実行方式 | (a)殿の手元実行を裁定する | 出典: `~/fable_ruling_20260729_q15q17.md` Q15。適用タイミング=即時(実害進行中: 家老311秒停滞)。二段構成(ps確認→殿目視→PID指定kill)

2026-07-29 | RULE | 経路非対称の扱い(switch_cli.sh等の破壊的操作) | 立場1を設計として採用する。ただし成文化は監査に委ね、(b)の建造も監査後とする | 出典: `~/fable_ruling_20260729_q15q17.md` Q16。「正規の制御された破壊経路」の資格要件明文化は全体監査議題へ

2026-07-29 | RULE | 「未確認の援用」族への対処(発令規律) | 「未確認の援用」—— 軽量な発令規律として制定する。仕組みは足さない | 出典: `~/fable_ruling_20260729_q15q17.md` Q17。発令規律へ1行追記(前例援用時は一次資料の所在明記、未確認は「未確認」と標識)

2026-08-04 | RULE | Q18: 出典未確認 | (該当なし) | **出典未確認**。`memory/MEMORY.md`内に「Q18-(1)(3)の実証データ」という言及(enforce移行後の初回実DENY顛末に関する項目)はあるが、`~/fable_ruling_*.md`6本・`memory/MEMORY.md`本文いずれにも対応する「## Q18」見出し・本文が存在しない(grep実施済み・0件)。推測で埋めず未確認として標識する。家老への申し送り事項とする

2026-07-29 17:45 | RULE | Q19: 全体監査の定義・Q12評価軸切替 | Q12の評価軸を「率の期間比較」から「機構レベルの帰属」へ切替える | 出典: `memory/MEMORY.md` 行67-95(「🔴Fable裁定 Q19・監査定義」節、cmd_137完了後に将軍が追記)。凍結の意味=新機能・新機構・新ルール追加cmdの停止/監査手順(殿宣言→基準commit記録→Fable静的監査→将軍是正cmd化)/done_with_caveat(cmd_054・068・072)を監査議題に含める、を含む

2026-08-04 | RULE | approval_queueとD001-D008の関係（恒久ルール、cmd_145殿裁定追加①） | 「approval_queueは承認の一元化であって禁止操作(D001-D008)の迂回路ではない」を**恒久ルール**と殿が定めた。judgment_model.mdの原則候補に必ず含め、ジャーナルへRULEで記帳し原則から参照せよ。 | 出典: `queue/shogun_to_karo.yaml` cmd_145 command末尾🔴節（追加1）、殿裁定2026-08-04

2026-08-04 | CORRECT | memory/MEMORY.md:161の出典記載 | (該当なし) | 出典: `queue/inbox/karo.yaml` msg_20260804_214624_7a5c31d7（将軍発・2026-08-04）、原文ママ引用: 「(3) memory/MEMORY.md:161の『_q15q17.md（Q15〜Q18）』は将軍の誤記であった。将軍が訂正する。家老はこれを出典として援用するな(これ自体が『未確認の援用』族の実例ゆえ、decisions_journal.mdへCORRECTで記帳せよ)。」

2026-08-04 | CORRECT | Q18出典探索範囲(59行目のQ18「出典未確認」RULE行の補訂) | 「足軽1号の『出典未確認』標識は当時の探索範囲では正しい。責は探索範囲を裁定書6本に限定指定した将軍にある。」 | 出典: `queue/inbox/karo.yaml` msg_20260804_215519_5210d0e6（将軍発・2026-08-04）。Fable原本の所在は`~/fable_ruling_*.md`6本ではなく`queue/inbox/shogun.yaml`（id: msg_20260729_fable_q18_enforce, from: fable, timestamp: 2026-07-29T16:20:00, cmd_id: cmd_fable_q18_enforce_migration）であった。裁定書ファイルには無くinbox経由で届いていたため6本のgrepで漏れた。過去エントリ書き換え禁止原則に従い、59行目のQ18「出典未確認」行はそのまま残す（当時の探索範囲では正当な判定だったため）。次行のRULEが更新後の正データ。

2026-08-04 | RULE | Q18: enforce移行後、真陽性のdenyが作業中に発火したときの扱い（裁定あり） | 「【Q18裁定】「添える」を採り、事前の合成テストは不要とする。」 | 出典3本併記: (a) Fable原本=`queue/inbox/shogun.yaml` msg_20260729_fable_q18_enforce（2026-07-29T16:20:00・from: fable・cmd_id: cmd_fable_q18_enforce_migration） (b) 殿の遡及裁定=`queue/inbox/karo.yaml` msg_20260804_215519_5210d0e6（将軍発・2026-08-04） (c) 問い本文=`~/fable_situation_20260729_1605.md:110-132`「### Q18: enforce移行後、真陽性のdenyが作業中に発火したときの扱い」。殿の遡及裁定はFable原本と実質一致（将軍が4論点を突合済み・矛盾なし、出典は(b)と同メッセージ）。実装紐付け=cmd_134工程2・`scripts/pretooluse_yaml_guard.sh:37 check_repeated_deny_alert()`（呼出は257行目、bats=`tests/unit/test_pretooluse_yaml_guard.bats`）。🔴実地未発火の事実: `logs/yaml_guard.log`の実DENY行は`2026-07-27T20:50:11`の1件のみでenforce切替（`config/settings.yaml:5` cmd_135, 2026-07-29 16:30:31）より前、enforce期の実DENYは依然0件、検証はbatsのみで本番未発火（誇張禁止）。

2026-08-04 23:15 | CORRECT | cmd_145 Part4完了判定の取消（`pretooluse_reversibility_check.sh`本番不活性） | 「実測(2026-08-04 23:02、将軍がshogun paneで直接実行): ...ログ1行も出ず。原因: config/settings.yamlにreversibility_check_enabledが存在しない...コード自体は正常...欠けているのはflag 1行のみである。」 | 出典: `queue/shogun_to_karo.yaml` cmd_145 `reopen_reason`（将軍記、2026-08-04 23:02実機検証）。「検証済みコードが稼働プロセスへ未到達」族の実例（cmd_144議題2で既に名指しされていた構造欠陥族）。軍師QC(gunshi_qc_145_part4・gunshi_qc_145_final)も模擬実行(env var上書き)による動作確認を本番稼働の証明として誤って受理しており見逃した(軍師自己レビュー`gunshi_self_review_145_part4_miss`)。是正=subtask_145_part4_fixで`reversibility_check_enabled: observe`をconfig/settings.yamlへ追加し本番経路(.claude/settings.json経由の実PreToolUse呼出し)で三値(reversible/irreversible/unknown)の実ログ出力を確認済み。再発防止則を`mandate/verifiers.md`・`instructions/gunshi.md` Step Gへ追加。

2026-08-04 | RULE | approval_queue持ち越し(AQ-001・AQ-002) | 「AQ-001および未push分のキュー消化は明日の裁定に持ち越すことを明示的に許可する。」 | 出典: `queue/inbox/karo.yaml` msg_20260805_002550_0d8b25c2（将軍発・2026-08-05T00:25:50、殿の陣仕舞い下命に対する補足）。承認キュー運用の初回適用。明示許可による持ち越しの第1号事例。

2026-08-05 | RULE | AQ-001承認(judgment_model.md初版の指揮層必読化) | 「Fableによる外部検証済み(全14原則の出典突合一致・160行以内・CoDD例外両ファイル明記確認)。条件つき承認である: approval_queue.md の AQ-001 doubt欄に残る陳腐化数字を実測値へ更新してから approved 処理せよ。」 | 出典: `queue/shogun_to_karo.yaml` cmd_147 command【A. AQ-001 — 承認】節、殿の2026-08-05一括裁定。実測: 原則14件(`grep -c "^## 原則" mandate/judgment_model.md`)・149行(160行以内)。judgment_model.md冒頭の未承認バナー削除済み。

2026-08-05 | RULE | cmd_144議題1: restart_watchers.sh建造可否 | 「D006記述の実態合わせを先行、restart_watchers.sh建造はその後(凍結解除後)。殿の言: 「実際より強い強制力を謳う記述はfail-loudの逆」の指摘は正しい。」 | 出典: `queue/shogun_to_karo.yaml` cmd_147 command【B】節1、一次資料はgunshi_audit_144 agenda1(`queue/reports/gunshi_report.yaml`)。軍師実機検証: `.claude/settings.json`のkill系denyはBashツール最上位コマンド文字列への前方一致のみで、スクリプト内部で呼ばれるkillは検査対象外(cmd_129が拒否された経路とは別)。建造自体は凍結解除後、本cmdでは実施しない。

2026-08-05 | RULE | cmd_144議題2: scope_check強制化の評価条件 | 「scope_check強制化は条件型へ改定(「生成物パス除外の建造後、逸脱検出N件」)。暦日期限は廃止。建造は凍結解除後。」 | 出典: `queue/shogun_to_karo.yaml` cmd_147 command【B】節2、一次資料はgunshi_audit_144 agenda2。根拠数値: `logs/scope_check_advisory.jsonl`31件(適合17/逸脱13/SKIP1)、逸脱13件中10件(77%)は生成物パス由来の偽陽性・1件混在・確証された真陽性は2件のみ。生成物パス除外の建造は凍結解除後、本cmdでは実施しない。

2026-08-05 | RULE | cmd_144議題3: done_with_caveat 3件(cmd_054/068/072)の確定 | 「done_with_caveat 3件は追加工数を投じない。ただし「未充足と確定済み」をステータスへ書き添えよ。」 | 出典: `queue/shogun_to_karo.yaml` cmd_147 command【B】節3、一次資料はgunshi_audit_144 agenda3。根拠: cmd_054は計測不能率92.1%(cmd_053の25%より悪化・要求と逆方向)、cmd_068は足軽1号報告(`queue/reports/ashigaru1_report.yaml:789-807`)で5区分すべて0.0s(全件None)、cmd_072は10体中8体再起動(karo/shogun自身の2体は権限拒否のため未実施)かつ計測不能率圧縮の実データ算出は判定不能。ステータス書き添え自体は別タスクsubtask_147bで実施。

2026-08-05 | RULE | cmd_144議題4: repeat-deny終了条件 | 「repeat-denyは受動継続・新条件不要。enforce後実DENY 0件の実測を了とする。」 | 出典: `queue/shogun_to_karo.yaml` cmd_147 command【B】節4、一次資料はgunshi_audit_144 agenda4。根拠: enforce移行(commit `73d589e`・2026-07-29 16:31:52)以降の実DENYは0件、`logs/yaml_guard.log`中の唯一のDENY行(2026-07-27T20:50:11)はenforce移行前の記録。0件を「機構が正しく動いている証明」とは読まない旨も踏まえた裁定。

2026-08-05 | RULE | cmd_144議題5: 新規feature flag常用化判断の主体統一 | 「新規flagの常用化判断はapproval_queueへ積んで殿が消化する形に統一する。」 | 出典: `queue/shogun_to_karo.yaml` cmd_147 command【B】節5、一次資料はgunshi_audit_144 agenda5。根拠: 殿タッチポイント47件中(a)委譲候補約30件・(b)維持約14件と暫定分類、`deadman_enabled`/`fastlane_enabled`の常用化判断主体がinstructions上どこにも明記されていないという非対称先例を発見(yaml_guard_enabled/stall_detection_enabledは客観条件型サインオフに既に収斂済み)。instructions側(karo.md該当節)への明記は別タスクsubtask_147bで実施。

2026-08-05 | RULE | cmd_144議題6: gunshi.md Step D項目6の是正方針 | 「gunshi.md Step D 項目6はStep Eへ統合。凍結解除後の別cmd。項目5は要再検討のまま。」 | 出典: `queue/shogun_to_karo.yaml` cmd_147 command【B】節6、一次資料はgunshi_audit_144 agenda6。根拠: `instructions/gunshi.md:284-285`項目6(複数Part間の整合性確認)が同294-296行の適用除外条件に巻き込まれ、項目7(cmd_142で既に是正済み)と同型の未是正欠陥と判明。項目6はcmd_127(commit `b328c6b`・2026-07-29)追加で、項目7の是正(cmd_142・2026-07-31)より2日前に同じ容器へ追加されていたが是正から漏れた。Step D統合の実施・gunshi.md本体の変更はいずれも本cmdでは行わない(凍結解除後の別cmd)。

2026-08-05 | RULE | cmd_149 Part A/B: ntfy新トピック名の伝達方法 | 「新ntfyトピック名の伝達は`~/ntfy_topic_new.txt`(git管理外・パーミッション600)経由とし、報告文・inbox・dashboard等git管理下のいかなる箇所にも値を書かない方式を採った。」 | 出典: `queue/shogun_to_karo.yaml` cmd_149 command【B】節、殿裁定2026-08-05。トピック名そのものはgit管理下のいかなるファイルにも書かない(本journalも例外ではない)。config/settings.yamlはgit追跡から除外済み(`git rm --cached`)、旧値は本rotation commit以降「死値」。

2026-08-05 | RULE | cmd_149 Part E: 「承認材料の数字の陳腐化」族の認定 | 「approval_queueエントリを殿の消化に出す直前、doubt欄の数値・件数を再実測して更新する」 | 出典: `queue/shogun_to_karo.yaml` cmd_149 command【E】節、殿裁定2026-08-05。実例2件: AQ-001 doubt(a)の`mandate/judgment_model.md`行数が137行→実測149行のまま放置されかけた事例、AQ-002 doubt(b)のunpushed commit件数が62件→65件と複数回(cmd_149 subtask_149b時点ではさらにpush直前の再実測値へ)陳腐化した事例。是正は`mandate/verifiers.md`「既知の機械的ミス防止則」への1行追加で行った。

2026-08-05 | CORRECT | cmd_149でのntfyトピックローテーション設計（⑤旧購読解除の欠落） | 「cmd_149 で将軍が設計した手順には⑤旧購読解除が欠けていた。旧トピック名はgit履歴に残ったままpushで公開されるゆえ、購読したままなら第三者が偽の通知を投げ込め、殿がそれを我が陣の報告と誤認し得る。購読解除して初めて死値となる。」 | 出典: `queue/shogun_to_karo.yaml` cmd_150 command【A】節（将軍記・自己申告）、殿の2026-08-05裁定。完全手順（①新名生成→②git外伝達→③購読替え→④到達確認→⑤旧購読解除→⑥push）は`mandate/verifiers.md`「ntfyトピックローテーション完全手順（cmd_150）」節へ1箇所に成文化した。

2026-08-05 | RULE | 記憶・判断基準の正本一本化（Memory MCP→mandate層） | 「復旧に工数を投じない。正本は decisions_journal.md / judgment_model.md / MEMORY.md とする。」 | 出典: `queue/shogun_to_karo.yaml` cmd_150 command【B】節、殿の2026-08-05裁定。Memory MCPグラフの復旧作業には今後工数を投じない。Session Start手順（CLAUDE.md・instructions/shogun.md・karo.md・gunshi.md）からMemory MCP読込の必須指定を外し、「利用可能なら読む(任意・失敗時はスキップ)」へ弱めた（mandate層＝judgment_model.md等の読込指定は維持）。MCPサーバ設定自体（`.mcp.json`等）は`find . -maxdepth 2 -iname ".mcp.json"`実測でリポジトリ内に0件確認され、除去可否の判断自体が不要であった。

2026-08-05 | RULE | cmd_138フィーチャーフリーズの解除 | 「cmd_138凍結の解除。監査議題6件の裁定・記帳完了をもって目的達成。」 | 出典: `queue/shogun_to_karo.yaml` cmd_150 command【C】節、殿の2026-08-05裁定。cmd_144で提起された監査議題6件の裁定・記帳（cmd_147・cmd_149・cmd_150にわたる）完了をもって、cmd_138フィーチャーフリーズの目的を達成したと認定する。凍結解除後の建造キュー（優先順・共通条件つき）の整備はdashboard.md側で家老が別途実施する（本journal記帳は範囲外）。

2026-08-05 | CORRECT | cmd_153: cmd_152分類器の穴(改行区切り複合・コマンド置換)を将軍実機検証で発見 | 「原因: `_DANGER_CHARS_RE = re.compile(r"[><;|&]")` に改行が含まれず、コマンド置換($()・バッククォート)も検出しない。Bashでは改行は`;`と同じコマンド区切りである。」 | 出典: `queue/shogun_to_karo.yaml` cmd_153 command(将軍記、2026-08-05実機検証)。cmd_152は軍師QCおよび反転194件の危険部分文字列再スキャンをいずれも通過していたが、これは「既存ログに危険な形の混入が無い」ことを示したに過ぎず「分類器が敵対的入力に対して安全」であることは示していなかった(judgment_model原則1: 観測失敗と否定的観測の同一視、の適用例。標本に無いことと有り得ないことは別物)。上流`IRREVERSIBLE_BASH`の`file_delete`パターン`(^|[;&|]\s*)rm\s`も`re.MULTILINE`欠落により同型の欠陥を持っていたが、これはcmd_152起因ではなく既存欠陥である(対照的に`git push`等の`\b`アンカーのみのパターンは改行複合でも構造的に捕捉される)。是正=`scripts/pretooluse_reversibility_check.sh`の`_DANGER_CHARS_RE`拡張(改行・`$(`・バッククォート追加)+`file_delete`パターンへの`re.MULTILINE`とアンカー文字集合拡張+`external_send`パターンのバックスラッシュ行継続対応+敵対的回帰テスト8形新設(`tests/unit/test_pretooluse_reversibility_check.bats`)。検証手法の限界は`mandate/verifiers.md`へ追記済み。Part4はobserve維持のまま(実害は出ていない)。

2026-08-08 | RULE | cmd_155 A/B: 原則引用検出規則+工程別時間内訳(裁定待ち/QC往復/実行)の境界定義(家老の設計決定) | 「「明示的に引かれた」の検出規則(どの文字列パターンを引用と数えるか、どのファイル群を走査対象とするか)を家老が定め、**明文化せよ**。曖昧なまま数えた数字は使えぬ。」「3工程の境界(どのイベントからどのイベントまでを各工程と定義するか)を家老が定め、**定義を明文化せよ**。定義なき数字は解釈できぬ。」 | 出典: `queue/shogun_to_karo.yaml` cmd_155 command【A. 殿の判断回数の計測(項目1)】節・【B. 工程別の時間内訳(項目2)】節。検出規則: リテラル文字列パターン`原則\d+`(例:「原則1」「原則12」)への正規表現一致、走査対象=`queue/shogun_to_karo.yaml`・`queue/reports/ashigaru*_report.yaml`・`queue/reports/gunshi_report.yaml`・`mandate/decisions_journal.md`・`mandate/approval_queue.md`・`dashboard.md`(明文化先: `mandate/verifiers.md`「原則引用回数の検出規則(cmd_155)」節)。工程境界3定義: ①実行=同一task_idの`agent_started`→`report_submitted`経過時間をcmd内全task_idで合算、②QC往復=同一cmd_id内で`report_submitted`後の次の`assigned`/`redo_dispatched`/`cmd_done`いずれかまでの経過時間の合算、③裁定待ち=`cmd_received`から当該cmdの最初の`assigned`までの経過時間(同一cmd_idに`lord_judgment_recorded`が存在する場合は承認待ち区間の参考値として併記可)。計測できない工程は0秒や「該当なし」へ潰さずunknownとして分離表示する(judgment_model原則1)。実装は`scripts/analyze_timing.py`への`--lord-judgments`/`--phase-breakdown`モード追加のみで行い、新規計測機構は建造していない。

2026-08-08 | RULE | AQ-004(「記述の強制力誇張」原則化申請)の条件付きpending据置 | 「単一事例での原則化は行わない。『文書の強制力誇張』の2例目が観測された時点で新設起案を再提出せよ(その際は本件を1例目として引くこと)。原則5への出典追加も行わない(対象が異なるため)。この判断理由をjournalへ記帳せよ。」 | 出典: `queue/shogun_to_karo.yaml` cmd_156 command【A】節、殿裁定2026-08-08。理由の要点2つ: ①単一事例(cmd_144議題1)のみでの原則化は偽陽性リスクを負う(weekly_distill.mdが警告する「実運用で実証されていない仮説の原則化」リスクに該当し得るため)。②原則5(サイレントな変更よりfail-loudを優先する)とは対象が異なる(原則5=コードの挙動の沈黙、本件=文書・記述側が実態を超えた強制力を謳う誇張)ため、原則5への出典追加による統合もしない。据置は`mandate/approval_queue.md` AQ-004エントリを「条件付きpending据置」へ更新し反映(再提出条件・弱い設計の自覚・機構化起票条件を明記)。`mandate/judgment_model.md`への変更は一切無し(git diffで無変更を機械確認、原則5の出典行を含め無変更)。

2026-08-08 | CORRECT | cmd_155-D: 週次蒸留 初回実行(2026-07-27〜2026-08-08 全39件) | 開始 2026-08-08 00:41:14、終了 2026-08-08 01:13:37(手動実行)。対象=`mandate/decisions_journal.md`Q1〜Q19および2026-08-04〜08-08の非Q番号エントリ、計39件全件。統合4件(原則1へ2件: cmd_144議題4「repeat-deny実DENY0件を機構正常証明と読まない」・cmd_153「分類器の敵対的安全性検証欠如」/ 原則3へ1件: memory/MEMORY.md:161出典記載CORRECT「未確認の援用族の実例」/ 原則4へ1件: cmd_144議題2「scope_check強制化評価条件の暦日期限廃止」)、新規1件→AQ-004 pending(「記述の強制力は実装の実態を超えて謳わない」、殿本人の発言「実際より強い強制力を謳う記述はfail-loudの逆」〈cmd_144議題1〉が根拠、原則5との統合可否をdoubt欄に明記)、重複17件(Q1-Q6・Q8-Q13・Q15-Q17・Q18確定エントリ・cmd_145裁定追加①の計17件、いずれもjudgment_model.mdへ既に反映済み)、対象外17件(内訳: 機械的ミス防止則として既にmandate/verifiers.mdへ収載済みにつき原則化不要5件〈Q18出典探索範囲補訂・cmd_145 Part4完了判定取消・ntfy新トピック伝達方法・ntfyローテーション⑤欠落・承認材料陳腐化族〉、単発かつ狭いスコープで一般化材料不足につき原則候補としなかった12件〈Q7・Q14・Q19・Q18出典未確認プレースホルダ・approval_queue持ち越し許可・AQ-001承認・cmd_144議題3/5/6・記憶正本一本化・cmd_138凍結解除・cmd_155A/B自体〉)。優先材料(「当否が決まる条件」列が埋まったエントリ)は0件であった(将軍事前注記どおり。当該列は今回蒸留の対象期間中に導入されたばかりで遡及追記していないため)。殿への未決事項=AQ-004の承認可否(judgment_model.md原則5への統合か独立新原則かを含む)。実行ログ=`logs/weekly_distill.log`。judgment_model.md行数=153行(160行以内、`wc -l`実測)。decisions_journal.md既存行の書き換えはゼロ(git diffで追記行のみであることを確認、後述)。 | 出典: `mandate/weekly_distill.md` Step1〜6、`queue/shogun_to_karo.yaml` cmd_155 command【D. 週次蒸留の初回実行(項目4)】節、殿の初回実行許可(2026-08-08、cmd_155 acceptance_criteria E-1〜E-4)。手動実行(cron未起動)。

2026-08-08 | NOTE | A-4自己言及インフレ(verifiers.md記載)⇄cmd_148ログ自己汚染(dashboard.md記載)の同族性・相互参照 | 「verifiers.mdへの明記(cmd_155-AB2で実施済み)は確認済みにつき追加対応は不要。ただしcmd_148(調査コマンドのログ汚染)との同族性をjournalの備考で相互参照させよ。」 | 出典: `queue/shogun_to_karo.yaml` cmd_156 command【C】節、殿裁定2026-08-08。同族性の芯: 観測する行為そのものが観測対象を変化させる。相互参照元(1): `dashboard.md:408`(cmd_148行、2026-08-08 09:20記載、実在をgrepで確認済み)「副産物: 調査コマンド自身がログを自己汚染する構造的な癖を発見、位置指定抽出(`awk '/^\[2026/{print $2}'`)を標準手法として申し送り」——調査コマンド自身がログを汚染した事例。相互参照元(2): `mandate/verifiers.md`「原則引用回数の検出規則（cmd_155）」節「自己言及による水増しの既知の限界」小節(subtask_155_AB2是正で追加)——判断引用回数を論じる報告書自身が引用回数を押し上げた事例(実例: `ashigaru1_report.yaml`のA-4実測値がashigaru1自身9件と記載したが`gunshi_qc_155_AB`独立再実行で実際は18件だった)。🔴注記: decisions_journal.md自体にはcmd_148・A-4それぞれを主題とする既存エントリは存在しない(実在確認済み・grep 0件、記録は上記2箇所〈dashboard.md/verifiers.md〉に分散していた)。本エントリは両者を初めて1箇所で相互参照するものであり、既存journalエントリの書き換えは行っていない(追記専用)。族への命名・新原則の起案はいずれも行わない(殿裁定2026-08-08「単一事例での原則化は行わない」〈AQ-004〉に従う)。種別は新規事実の裁定(RULE)でも自己訂正(CORRECT)でもないため、便宜上「NOTE」(相互参照専用の記帳)とした——本ファイル冒頭の種別定義(RULE/REJECT/CORRECT)には無い値であり、家老・軍師への申し送り事項とする。

2026-08-08 | RULE | 「誤記是正」と「機構新設」の線引き(cmd_157-A適用可否) | 「本件(cmd_157-A)は機構の新設ではなく既存条文の誤記是正であり、『観測が先、機構は後』の適用対象外とする——実害は既に観測済み(cmd_156通知欠落)、対処は建造ではなく1行修正、原因は制定時の経緯による字面と趣旨の乖離と特定済みのためである。この線引き(誤記是正と機構新設の区別)をjournalへ記帳せよ。」 | 出典: `queue/shogun_to_karo.yaml` cmd_157 command【B. 「誤記是正 vs 機構新設」の線引きを記帳(殿裁定)】節、殿裁定2026-08-08。4つの根拠: (1)実害が既に観測済み(cmd_156の完了通知が殿へ届かなかったという具体的実害)。(2)対処が建造でなく1行修正(`instructions/karo.md:896`・`instructions/shogun.md:264`の該当行の文言修正のみで、新規スクリプト・新規flag等の建造を伴わない)。(3)原因が特定済み(cmd_157-Aで是正済み・原因追跡が完了している)。(4)原因が制定時(cmd_136・2026-07-29)の経緯による字面と趣旨の乖離であること(殿の裁定がFable経由で届いていた時期の字面「Fable裁定案件」がそのまま残り、趣旨「統治事項は従来どおり」と乖離していた)。🔴AQ-004(cmd_155-D由来)との区別: AQ-004は「新原則を単一事例で創る」話——新規の判断原則をjudgment_model.mdへ追加してよいかという議題であり、本件(cmd_157-B)は「既存条文の誤記を直す」話——既に存在するinstructions文書の字面と趣旨の乖離を1行修正で正す議題である。対象が違う(前者=新規原則の創設可否、後者=既存条文の誤記修正可否)ため、両者は矛盾しない。

2026-08-08 | CORRECT | cmd_149でのntfyトピックローテーション設計（⑤旧購読解除の欠落）の解消確定(cmd_159殿裁定(1)) | 「(1)旧トピック購読(cmd_149手順⑤): 殿ご自身がntfyアプリを実確認され『既に解除済み』と確定。これをもって手順⑤の実施を確定とし、実施日時と本裁定を出典として mandate/decisions_journal.md へ記帳し、dashboard.md🚨該当項目をクローズせよ。**実施記録の欠落を発見した軍師の調査は殊勲である旨も記録に残せ**。」 | 出典: `queue/shogun_to_karo.yaml` cmd_159 command(1)節（将軍発、`queue/inbox/karo.yaml` msg_20260808_224538_e08c1bbd 経由で家老へ伝達）、殿裁定2026-08-08T22:45:00(cmd_159殿裁定確認時点)。確定した事実は「殿が2026-08-08時点でntfyアプリを実確認し、旧トピックの購読は既に解除済みであると確認された」ことのみであり、購読解除操作自体が実施された日時は不明のため推測で記載しない。これをもって`mandate/verifiers.md`「ntfyトピックローテーション完全手順（cmd_150）」節の手順⑤(旧購読解除)の実施が確定し、本journal112行目(CORRECTエントリ、将軍の自己申告)で指摘されていた「⑤の欠落」は解消されたと認定する。🔴実施記録の欠落(`mandate/approval_queue.md` AQ-005③、`queue/reports/gunshi_report.yaml task_id: gunshi_qc_158_G`)を発見した軍師の調査は殊勲である旨、殿ご自身が明記された(出典: cmd_159殿裁定(1)本文)。dashboard.md🚨該当項目のクローズは別タスクで対応(本エントリの記帳自体の範囲外)。

2026-08-08 | RULE | 秘匿値の無害化(公開済み履歴中の値)が成立する条件(cmd_159殿裁定(2)) | 「(2)公開済み履歴11commitの残存: 公開履歴の書換えは行わない。家老の暫定結論(ローテーション済みで値は無効)を採用し subtask_158_H の独立検証で閉じよ。🔴無害化の成立条件は『値ローテーション済み』かつ『旧購読解除済み』の**2点セット**であることを記録に明記せよ(片方だけでは無害化は成立せぬ)。」 | 出典: `queue/shogun_to_karo.yaml` cmd_159 command(2)節、殿裁定2026-08-08。既に公開されてしまった秘匿値(ntfy_topic等)が実害を持たなくなるための条件は、①値そのものがローテーション済みであること、②旧チャネル(旧トピック)の購読が解除済みであること、の2点セットであり、片方のみでは無害化は成立しない。根拠事例(cmd_158): ①値ローテーション済みの確認は`subtask_158_H`にてローテーション前後のntfy_topic値のSHA256ハッシュ比較(`git show 60a0299^:config/settings.yaml`側のローテーション前値と現在値)で不一致=値が異なることを独立検証済み(出典: `mandate/approval_queue.md` AQ-005追記②)。②旧購読解除の確認は本journal直前のCORRECTエントリ(上記、cmd_159殿裁定(1))で殿ご自身が確認済み。①②が独立に完了して初めて、dda6b30〜60a0299間の11件の公開済み既存履歴に含まれるntfy_topic値は無害化されたと認定する。
