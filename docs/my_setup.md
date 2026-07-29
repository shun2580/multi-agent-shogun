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
将軍 ── Claude Code（Sonnet 4.6）
│　　　戦略判断・タスク分解・統括
▼
家老 ── Claude Code（Sonnet 4.6）
│　　　タスク分解・足軽への割当・品質判定
│
▼
軍師 ── Claude Code（Sonnet 4.6）
│　　　品質チェック・ダッシュボード更新
│
├──────────┬──────────┬──────────┬──────────┬──────────┬──────────┐
▼          ▼          ▼          ▼          ▼          ▼          ▼
足軽1      足軽2      足軽3         足軽4      足軽5      足軽6      足軽7
Sonnet     Sonnet     gpt-oss       Ollama     Haiku      Haiku      Haiku
4.6        4.6        120b:free     qwen3.5:9b 4.5        4.5        4.5
（重量）   （重量）   （OpenRouter） （ローカル）（軽量）   （軽量）   （軽量）
```

### エージェント一覧

| エージェント | CLI | モデル | 役割 |
|---|---|---|---|
| 将軍（Shogun） | Claude Code | claude-opus-5 | 戦略決定・家老へのcmd下達 |
| 家老（Karo） | Claude Code | claude-sonnet-5 | タスク分解・足軽への割当・品質判定 |
| 軍師（Gunshi） | Claude Code | claude-sonnet-5 | 品質チェック・ダッシュボード更新 |
| 足軽1-4（Ashigaru1-4） | Claude Code | claude-sonnet-5 | 重量実行タスク（常時稼働） |
| 足軽5（Ashigaru5） | Claude Code | claude-haiku-4-5-20251001 | 高速軽量タスク（常時稼働） |
| 足軽6/7（Ashigaru6/7） | Claude Code | claude-haiku-4-5-20251001 | 高速軽量タスク（Haiku枠） |

> 🔴cmd_133是正: 足軽3/4の行はOpenCode+OpenRouter/Ollama時代のまま放置され、
> フリート全Claude化（cmd_133でSonnet帯4席化）後も表が実態を追従していなかった。
> 「表示と実態の乖離」族（cmd_116 S-2のWATCHER_STATUS虚偽表示、cmd_128の
> dashboard時刻列と同族）として記録する。
>
> 注: 上表の足軽1-4行（Sonnet帯4席化）は**次回出陣（`shutsujin_departure.sh`実行）後に
> 有効**となる設定である。本ページ更新時点（config/settings.yaml反映はsubtask_133a
> commit `ea82190` 済み）では、足軽3/4の実プロセスはまだ`claude-haiku-4-5-20251001`で
> 稼働中（軍師QC時点で確認）。次回出陣まではこの1行は意図的な前倒し記載である。

---

## コスト構成

| 項目 | コスト |
|---|---|
| Claude Max 5x（将軍・家老・軍師・足軽1/2/5） | $100/月（固定） |
| OpenRouter（足軽3） | 無料（$10一度購入で1000req/日解放・以降は無料運用） |
| Ollama（足軽4） | 無料（自PC・GPU推論） |
| **合計** | **$100/月** |

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
| Ollama | qwen3.5:9b（GPU推論） |
| Gemini CLI | v0.44.1 |
| OpenCode | ashigaru4（Ollama連携LLM実行） |
| 既存ツール | VSCode＋GitHub Copilot（併用継続） |

---

## 工夫した点・学んだこと

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