# multi-agent-shogun + CoDD 環境構築まとめ

## 概要

[multi-agent-shogun](https://github.com/yohey-w/multi-agent-shogun) と [CoDD（整合性駆動開発）](https://github.com/yohey-w/codd-dev) を組み合わせた低コスト・高効率な開発環境の構築記録。

Claude Max 5x（$100/月）にアップグレードし、自分のPCスペック（GPU VRAM 8GB）に最適化した構成を構築した。

---

## 参考記事

- [multi-agent-shogun 紹介記事](https://zenn.dev/shio_shoppaize/articles/5fee11d03a11a1)
- [CoDD グリーンフィールドガイド](https://zenn.dev/shio_shoppaize/articles/codd-greenfield-guide)
- [CoDD と将軍の合体記事](https://zenn.dev/shio_shoppaize/articles/codd-evolve-conversational)
- [OpenCode対応（v5.0.0）](https://zenn.dev/shio_shoppaize/articles/shogun-opencode-v5-openrouter)

---

## 元の構成（リポジトリ初期状態）

| 項目 | 初期値 |
|---|---|
| エージェント数 | Shogun + Karo + Ashigaru×8（計10体） |
| 使用CLI | Claude Codeのみ |
| モデル | 未明示（実質Opus） |
| 通信方式 | YAMLファイル＋ポーリング（5〜10秒間隔） |
| 軍師（Gunshi） | なし |
| エージェント設定 | setup.shにハードコード |
| preflight check | なし |
| CoDD連携スキル | なし |
| 想定コスト | Claude Max $100〜$200/月 |

---

## 構築の経緯

最初は Claude Pro（$20/月）＋ Ollama ローカルLLM のミニマム構成で構築を開始した。
しかし運用する中で以下の課題が表面化した。

- **ローカルLLMの指示理解不足**: 進捗確認時に足軽（Ollama）が家老からの指示を正しく解釈できず、同じ処理をループし続けるケースが頻発。人間が介入して手動でリセットする必要があり、自律実行の妨げになっていた。
- **5時間の利用量制限**: Proプランのレート制限により、集中して開発を進めたい場面でエージェントが停止する問題が発生。

これらを解消するため Claude Max 5x（$100/月）へアップグレードし、重量タスクをSonnet足軽・軽量タスクをHaiku足軽へ振り分ける現在の構成に移行した。Gemini CLI と Ollama は無料枠として引き続き維持し、Claude 枠の消費をタスク性質で使い分ける設計とした。

---

## 自分の環境への最適化（変更点と理由）

| 変更内容 | 変更前 | 変更後 | 理由 |
|---|---|---|---|
| 指揮層モデル | Opus | Sonnet | ProプランではOpus使用不可 |
| 通信方式 | ポーリング（5〜10秒間隔） | イベント駆動（inotifywait） | API無駄遣い防止・応答速度改善 |
| 足軽構成 | Claude Code×8 | Sonnet×2＋Haiku×1＋Gemini CLI×3＋Ollama×1 | Claude Max枠を活用しつつ無料枠・ローカルで補完 |
| 足軽数 | 8体 | 常設7体（足軽1〜7） | Max 5xプランでClaude枠拡大・Gemini並列で補強 |
| preflight check | なし | あり（preflight_check.sh） | inotify-tools欠落による全停止事故の再発防止 |
| 家老判断ルール | 暗黙的（基準曖昧） | 明文化（cmd_003/004） | 不必要なHaiku昇格によるClaude枠消費を削減 |
| CoDD連携スキル | なし | codd-greenfield / codd-evolve | 話しかけるだけで全工程を自動実行 |
| 家老の自己リセット | 手動介入が必要 | コンテキスト高騰時にinbox_writeで自動/clear | 殿が介入せずとも家老が自律リセットして作業継続 |

---

## 現在の構成

```
あなた（殿）
│
│ 自然言語で指示・承認のみ
▼
将軍 ── Claude Code（Opus 5.5）
│　　　戦略判断・タスク分解・統括
▼
家老 ── Claude Code（Sonnet 5.5）
│　　　タスク分解・足軽への割当・品質判定
│
▼
軍師 ── Claude Code（Sonnet 5.5）
│　　　品質チェック・ダッシュボード更新
│
├──────────┬──────────┬──────────┬──────────┬──────────┬──────────┐
▼          ▼          ▼          ▼          ▼          ▼          ▼
足軽1      足軽2      足軽3      足軽4      足軽5      足軽6      足軽7
Sonnet     Sonnet     Sonnet     Sonnet     Sonnet     Haiku      Haiku
5.5        5.5        5.5        5.5        5.5        5.5        5.5
（重量）   （重量）   （重量）   （重量）   （重量）   （軽量）   （軽量）
```

### エージェント一覧

| エージェント | CLI | モデル | 役割 |
|---|---|---|---|
| 将軍（Shogun） | Claude Code | claude-opus-5-5 | 戦略決定・家老へのcmd下達 |
| 家老（Karo） | Claude Code | claude-sonnet-5-5 | タスク分解・足軽への割当・品質判定 |
| 軍師（Gunshi） | Claude Code | claude-sonnet-5-5 | 品質チェック・ダッシュボード更新 |
| 足軽1-5（Ashigaru1-5） | Claude Code | claude-sonnet-5-5 | 重量実行タスク（常時稼働） |
| 足軽6/7（Ashigaru6/7） | Claude Code | claude-haiku-5-5（effort: medium） | 高速軽量タスク（Haiku枠） |

> 布陣の一次資料は `config/settings.yaml`。本表と食い違うときは settings.yaml を正とする。詳細は末尾の「現在の環境の状態」を参照。

---

## コスト構成

| 項目 | コスト |
|---|---|
| Claude Max 5x（全10体） | $100/月（固定） |
| Gemini CLI・OpenCode・Ollama | 休眠中（0円） |
| **合計** | **$100/月** |

> 旧構成では OpenRouter（足軽3）と Ollama（足軽4）を無料枠として併用していた。現在は全員 Claude Code で動かしている。

---

## 開発フロー

### 新規プロジェクト（Greenfield）

将軍に話しかけるだけで全工程が自動実行される（/codd-greenfieldスキル）。

```
殿：「GoのWebAPIを作りたい。機能は〇〇と△△」
　↓
将軍が /codd-greenfield を自動発動
　↓
要件書作成（requirements/*.md）
　↓
codd init
　↓
codd generate --wave 2（wave_config を自動生成し設計書を出力）
　↓
【殿：設計書レビュー・承認】← Wave ごとに必須
　↓
codd generate --wave 3〜N（承認されるまで次 Wave に進まない）
　↓
codd validate → codd implement → codd assemble → codd verify
　↓
完了報告（コミット承認を待つ）
```

### 機能追加・修正（Brownfield）

将軍に話しかけるだけで全工程が自動実行される（/codd-evolveスキル）。

```
殿：「ログアウト追加して」
　↓
将軍が /codd-evolve を自動発動
　↓
設計書・コード・テストが自動更新
　↓
完了報告
```

### スキル使い分け

| スキル | 用途 | 発動タイミング |
|---|---|---|
| /codd-greenfield | 新規プロジェクト（init→verify全自動） | 「〇〇を作りたい」と話しかけたとき |
| /codd-evolve | 既存プロジェクトへの修正・機能追加 | 「〇〇追加して」と話しかけたとき |

**ポイント：要件の質がそのまま出力品質になる。**  
要件が明確 → 設計書の品質が上がる → 足軽（Ollama/Gemini）への指示が明確になる → コード品質が向上する。

---

## 構築環境

| 項目 | 内容 |
|---|---|
| OS | Windows 11 |
| WSL2 | Ubuntu（Dドライブに構築） |
| GPU | RTX 4060 Ti 8GB |
| Claude Code | Max 5x $100/月 |
| Ollama | qwen3.5:9b（GPU推論。休眠中） |
| Gemini CLI | v0.44.1（休眠中） |
| OpenCode | 休眠中（旧構成では ashigaru4 の Ollama 連携に使用） |
| 既存ツール | VSCode＋GitHub Copilot（併用継続） |

---

## 工夫した点・学んだこと

> 本節のうち、Ollama・Gemini CLI・OpenCode を使った足軽の使い分けは旧構成時の学び。現在は全員 Claude Code で動かしている。

**コスト削減の核心はイベント駆動**  
ポーリング方式だとAPI消費が爆発するが、inotifywait によるイベント駆動にすることで待機中のAPI消費をゼロにできる。

**GPUのVRAMがOllamaの同時推論数の上限を決める**  
qwen3.5:9bは約6〜8GBのVRAMを使用する。RTX 4060 Ti 8GBでは実質1体のGPU推論が上限であり、Ollamaは足軽4の1体に限定している。Gemini CLIはGPUを使わないため、VRAM消費ゼロで足軽3/6/7として並列追加できる。

**要件の質がそのままコード品質になる**  
CoDDは要件を忠実に展開するツールのため、入力の質がそのままコード品質になる。AIは書いていないことは作らない。

**タスク性質に応じた足軽の使い分けが品質とコストのバランスを決める**  
重量タスク（複雑な実装・設計）はSonnet足軽1/2へ、高速軽量タスク（単純な変換・確認）はHaiku足軽5へ、調査・並列処理はGemini足軽3/6/7へ、完全ローカルで済むタスクはOllama足軽4へ振り分けることで、Claude Max枠の消費を最適化できる。

**話しかけるだけで開発が進む設計が重要**  
coddコマンドを手動で打つ運用はレート制限と手間の両方の問題になる。スキル化することでGreenfieldもBrownfieldも自然言語の指示だけで完結する。

**スマホへのプッシュ通知でハンズフリー運用が完成する**
ntfy（無料のプッシュ通知サービス）を導入することで、cmd完了・エラー・要対応イベントをスマホにリアルタイム通知できる。「指示を出して離席→完了通知が届いたら確認」というハンズフリーの開発フローが実現する。

**自己回復機能でエージェントの詰まりを自動解消**
家老がコンテキスト使用量の増大を検知した際に自律的に/clearを実行する仕組みと、CLI切替後の疎通確認・5分無応答時の別エージェントへの自動再割当てを実装した。これにより殿が介入しなくてもcmdが完走する環境を実現した。

**異なるCLI間の通信プロトコル統合**
Claude Code・Gemini CLI・OpenCode はそれぞれ異なるインターフェースを持つ。「inbox3」という短い起動シグナルは Claude Code しか解釈できないため、inbox_watcher.sh でエージェントのCLI種別を判定し、非Claudeエージェントには明示的なタスク指示文を生成して送信・inbox の自動既読処理を行う仕組みを実装した。これにより異種CLIを同一パイプラインで統一的に稼働させることが可能になった。

---

## 現在の環境の状態（2026-10-15時点）

> 本節が現況の正。上の「元の構成」「構築の経緯」「自分の環境への最適化」「工夫した点」は経緯の記録。布陣と設定の一次資料は `config/settings.yaml`（git 追跡外の手元設定。書式は `settings.yaml.example`）。
> 2026-10 に上流（yohey-w/multi-agent-shogun）を土台に建て直し、自家製の監視・関門の仕組みの多くを外した。

### 布陣

| エージェント | モデル | effort |
|---|---|---|
| 将軍 | claude-opus-5-5 | high |
| 家老・軍師 | claude-sonnet-5-5 | high |
| 足軽1〜5 | claude-sonnet-5-5 | high |
| 足軽6/7 | claude-haiku-5-5 | medium（2026-10-15 に Haiku 4.5 から切替） |

- 起動コマンドは `lib/cli_adapter.sh` の `build_cli_command` が settings.yaml から組み立てる（出陣スクリプト・`scripts/switch_cli.sh` の両方が使う）。
- Gemini CLI・OpenCode・Ollama は休眠（削除せず温存）。

### Claude Code Mods（2026-10 導入）

観察と表示のみに使う。tool 呼び出し・プロンプト・モデルに渡す文脈は変えない（拒否・承認・代理応答もしない）。各エージェントの起動時に `--plugin-dir` で読み込む。宣言は settings.yaml の `cli.agents.<名>.mods`、本体は `mods/` 配下（git 追跡）。

| Mod | 読み込む先 | 内容 |
|---|---|---|
| mods/status | 将軍のみ | プロンプトの上の帯に、進行中の cmd 数・🚨件数・各エージェントの状態を1行で表示。前提どおりに読めないときは 0 ではなく「?」を出す |
| mods/audit | 全10体 | tool 呼び出しとターンの開始・完了を `logs/audit/YYYY-MM/<エージェント名>.jsonl` に追記（git 追跡外）。記録は tool 名・対象パス・成否のみで、Bash のコマンド文字列は残さない |
| mods/banner | 全10体 | プロンプトの上に役職名（⚔ 将軍 など）を表示 |
| mods/toolrow | 全10体 | tool 呼び出しの見出し行を武士風の名に言い換え、元の名を括弧で残す（例: 陣触れ（Bash））。通常の画面では Bash などの呼び出しは畳まれて集計行になるため、詳細表示で見える |

- 考え中の動詞の武士風表示は Mod ではなく `.claude/settings.json` の `spinnerVerbs` で行う。
- 外す手順: settings.yaml の mods 欄から消して起動し直す。

### 見張り役（inbox_watcher）

- 起こしのキーを送るのは、送る直前に画面を見て「待機中のプロンプト」と判じたときだけ。作業中・確認画面・判別できない画面には送らない（cmd_231）。
- 働き中の足軽に /clear は送らない。働き中が長く続くときは ntfy で殿に知らせる（settings.yaml の `busy_guard`: 未読30分・連続60分・再通知60分）。
- 経緯: 旧版は待機の目印ファイルだけを根拠に待機中と判じており、作業中の足軽への打鍵や、確認画面で Enter が「Yes」を選んでしまう事故が起きた（cmd_232 で洗い出し）。
- 試験のうち tests/e2e は使い捨ての tmux セッションでしか走らない（`scripts/run_e2e_isolated.sh` 経由。cmd_225）。生きた陣のペインへキーを送っていた事故を受けたもの。

### 有効な feature flags（settings.yaml）

| flag | 値 | 内容 |
|---|---|---|
| yaml_guard_enabled | **enforce** | queue などの YAML への書き込みを守る（cmd_135） |
| reporting_mode | **exception** | 正常完了は dashboard 記録のみ。ntfy は失敗・ブロック・caveat 付き完了・殿の裁定要のときのみ（cmd_136） |
| git_push_block_enabled | **enforce** | PreToolUse で git push を止める。事故防止の層であり、境界は下記の資格情報の分離が担う |
| parent_cmd_done_gate_enabled | **enforce** | 配下の task に未完了が残る cmd を done にさせない（cmd_164） |

- feature_freeze は無効（2026-08-05 解除）。

### 秘匿値と push の運用

- 秘匿値はリポジトリの外の `secrets.env` に置き、エージェントには読ませない（`permissions.deny`）。文書では鍵名で言及し、値は書かない。
- push の前に pre-push hook（`scripts/githooks/pre-push`）が秘匿値の混入を照合する。
- push は殿が手元の端末から、パスフレーズ付きの SSH 鍵で行う。fetch は HTTPS、push 先は SSH。エージェントの手の届く所に GitHub へ書き込める資格情報は置かない（2026-10-11 に旧い資格情報を失効させ、実測で確認）。
- 殿の承認を要するのは、不可逆な操作（D001〜D008）・push・金銭のみ。それ以外は将軍が決め、`mandate/decisions_journal.md` に記帳する。

### 保留中

- 開発リポジトリへのブランチ push の委任: 設計のみ済み。エージェントに push させる開発を始めるときに判断する。
- 既知の失敗試験（TC-BLOOM、build_system #1/#78）を 0 件にする整備: 未着手。