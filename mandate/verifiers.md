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
