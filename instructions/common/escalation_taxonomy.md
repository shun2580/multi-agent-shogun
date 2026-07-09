# Escalation Taxonomy

## 用語集

| 用語 | 意味 | 層 | 具体例 |
|---|---|---|---|
| **nudge強度**（インフラ層） | inbox監視daemonが未応答エージェントを起こす際の介入の強さの段階 | システム内部の配送メカニズム | `inbox_watcher.sh`の0-2分=通常nudge/2-4分=Escape×2/4分+=`/clear`強制 |
| **判断エスカレーション**（人間判断層） | エージェントが自律判断を止め、殿の意思決定を仰ぐこと | 人間とのインターフェース | dashboard.md 🚨要対応記載・`ntfy.sh`通知・Tier2 STOP-AND-REPORT |

この2層は独立した概念であり、「nudge強度が上がる」ことと「殿へ判断エスカレーションする」
ことは連動する場合もあれば（例: auto_heal閾値到達時のntfy）、しない場合もある（例:
`/clear`強制は純粋なnudge強度の最終段階で、殿への相談を伴わない）。既存文書ではこの2つを
同じ「エスカレーション」という語で無自覚に併用しているため、今後の追記では本用語集に従い
明確に書き分ける。

## 判断タクソノミー

「どの分岐が殿の判断を要し、どれが自律進行してよいか」を一枚に統合する（既存の
Forbidden Actions / Destructive Operation Safety / Action Required Rule との対応込み）。

| # | 分岐の種類 | 現行の扱い | 根拠 | 強制方式 |
|---|---|---|---|---|
| 1 | 破壊的操作 D001-D008（`rm -rf`外部, force push, `git reset --hard`等） | **絶対拒否**（殿判断すら経ない即REFUSE） | CLAUDE.md Destructive Operation Safety Tier1 | LLM自己規律のみ（コード上のガードレールなし＝エージェントの倫理規約に依存） |
| 2 | Tier2 STOP-AND-REPORT（>10ファイル削除・プロジェクト外変更・未知URL・破壊性不明） | 殿へ**要確認**（ただし文言は"notify Karo/Shogun"であり殿到達を明言せず） | CLAUDE.md Destructive Operation Safety Tier2 | LLM自己規律のみ |
| 3 | git push の承認 | **文書間で矛盾**（詳細は`docs/loop_engineering_design.md`§4-1）。F007は「殿の事前承認必須」、karo.md比例分解ルールは「低リスクは単一足軽サブタスク+軍師QC1回で完結、殿確認は明記なし」 | `instructions/common/forbidden_actions.md`(F007) vs `karo.md:351-365` | 一部コード(`scope_check.sh`でpush先ファイル確認)だが承認有無はコード検証対象外 |
| 4 | Redo（足軽の成果物が不十分） | 2回まで自律redo、3回目で殿へ | `karo.md:811` | **テキスト規約のみ**（カウンタはコードになし） |
| 5 | 詰まり検知（足軽/軍師無応答） | 自己回復を2回試行、失敗継続で殿へ | `karo.md:1229`, `karo.md:1247` | **テキスト規約のみ** |
| 6 | 自動蘇生（CLIクラッシュ） | 10分内3回蘇生で殿へntfy | `scripts/inbox_watcher.sh:1360-1420`(`config/settings.yaml`の`auto_heal:`) | **コード強制**（jsonlログ+カウンタ） |
| 7 | OSS PR判断（重大な設計不一致） | 「Shogunへエスカレーション」——**殿ではなくShogunエージェントまで** | `karo.md:1122-1127` | LLM自己規律のみ。Shogunがさらに殿へ上げるかは未規定（曖昧） |
| 8 | スキル化候補 | dashboard記載＋🚨要対応で殿承認を仰ぐ | `karo.md:716-721` | テキスト規約 |
| 9 | タスクの人/AI振り分けが曖昧 | 「Ask Lord」 | `shogun.md:212`, `shogun.md:284` | テキスト規約 |
| 10 | バッチ処理①-⑥のbatch1 QCゲート | 「Shogun QC」——殿本人への相談かエージェント内判断か不明記 | CLAUDE.md Batch Processing Protocol | **曖昧**（誰が最終判断者か未定義） |
| 11 | モデル自動更新の適用 | **常に殿承認必須**（自動適用コード自体が存在しない） | `scripts/model_update_check.py:12,197-215` | コード強制（適用経路が物理的に存在しない） |
| 12 | dashboard 🚨要対応の一般カテゴリ | 「殿の判断が必要な事象」全般（copyright/tech choice/blocker/question等） | CLAUDE.md #7 + `karo.md:646-652`のチェックリスト | テキスト規約。**該当基準がCLAUDE.md(抽象的)とkaro.md(具体列挙)とshogun.md(別の具体例)で三重に分散** |
| 13 | Northstar違反の疑い | 軍師が"⚠️ North Star violation"として報告に明記 | `instructions/gunshi.md:155` | テキスト規約（軍師の自己申告のみ） |

## 参照

本ファイルの更新は `docs/loop_engineering_design.md` と `docs/instruction_system_consolidation.md` を一次資料として行うこと。

## リトライ閾値一覧とrationale

| 種別 | 閾値 | 単位 | 導入cmd | rationale |
|---|---|---|---|---|
| nudge強度 | 2分/4分 | 時間ベース | 既存(cmd番号未確認) | 段階的にnudgeを強める設計。一次資料未確認 |
| auto_heal | 3回/10分 | 回数+時間窓 | cmd_052d | 短時間の連続クラッシュのみ異常とみなす設計。時間窓により偶発的な単発クラッシュと区別 |
| redo | 2回 | 累計回数 | cmd_065(起点はcmd_017由来) | 「2回同じ対処で解決しなければ殿へ」という既存運用ルールをコード強制化したもの |
| 詰まり | 2回 | 累計回数 | cmd_065(起点はcmd_017由来) | 同上 |

4種の閾値には統一根拠が存在しない。それぞれ異なる時期・異なる文脈で個別に定められた
ものであり、本表はそれを正直に文書化するものである(閾値自体の変更は行わない)。
