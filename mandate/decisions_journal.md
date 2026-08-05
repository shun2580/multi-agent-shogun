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
