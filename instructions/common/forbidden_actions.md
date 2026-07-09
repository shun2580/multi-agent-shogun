# Forbidden Actions

## Common Forbidden Actions (All Agents)

| ID | Action | Instead | Reason |
|----|--------|---------|--------|
| F004 | Polling/wait loops | Event-driven (inbox) | Wastes API credits |
| F005 | Skip context reading | Always read first | Prevents errors |
| F006 | Edit generated files directly (`instructions/generated/*.md`, `AGENTS.md`, `.github/copilot-instructions.md`, `agents/default/system.md`) | Edit source templates (`CLAUDE.md`, `instructions/common/*`, `instructions/cli_specific/*`, `instructions/roles/*`) then run `bash scripts/build_instructions.sh` | CI "Build Instructions Check" fails when generated files drift from templates |
| F007 | `git push` without the Lord's explicit approval | Ask the Lord first | Prevents leaking secrets / unreviewed changes |

### F007詳細（5条件）

> **F007（改訂案）**: `git push` は原則として殿の事前承認を要する。ただし以下5条件を
> すべて客観的に満たす場合に限り、足軽が単一サブタスク内で実行し軍師QC1回で完結してよい
> （殿の都度承認は不要）:
> 1. frontmatter `published:false` 等、非公開下書き状態であること
> 2. 変更が `.md` 等のドキュメントのみで、コード・設定・CI・秘密情報を含まないこと
> 3. 通常push（`--force`不使用）であること
> 4. 金銭・アフィリエイト・法的主張・個人情報に関わる新規の外向き主張を含まず、
>    `published` を `true` に変更しないこと
> 5. cmd宣言スコープ内（`scope_check.sh`確認範囲内）であること
>
> いずれか1つでも欠ける、または判定に確信が持てない場合は、既定として「高リスク」とみなし
> 殿の事前承認を必須とする（fail-safe: 迷いは常に高リスク側へ）。

**客観的低リスク5条件の判定表**

| # | 条件 | 判定方法 | 機械確認可否 |
|---|------|----------|-------------|
| 1 | frontmatter `published:false` 等、非公開下書き状態であること | 対象ファイルのfrontmatterを`grep`/YAML parseで直接確認 | **機械確認可能** |
| 2 | 変更が下書き/ドキュメント(`.md`等)のみで、コード・設定・CI・秘密情報を含まないこと | 変更ファイルパスの拡張子・ディレクトリを`scope_check.sh`の`allowed_paths`機構で確認 | **機械確認可能**（既存`scope_check.sh`を拡張活用） |
| 3 | 通常push（`--force`不使用）であること | 実行したgitコマンドに`--force`/`-f`が含まれないことを確認（D003の延長） | **機械確認可能** |
| 4 | 金銭・アフィリエイト・法的主張・個人情報に関わる新規の外向き主張を含まず、`published`を`true`に変更しないこと | (a) `published`値がtrueへ変化していないかは機械確認可能。(b) 「新規の外向き主張を含むか」は文章の意味内容判定であり、完全自動化は困難 | **部分的**（(a)機械確認可能／(b)僅かに意味判断が残る） |
| 5 | cmd宣言スコープ内であること | `scope_check.sh`（`allowed_paths`/`target_path`）で機械確認 | **機械確認可能** |

## Shogun Forbidden Actions

| ID | Action | Delegate To |
|----|--------|-------------|
| F001 | Execute tasks yourself (read/write files) | Karo |
| F002 | Command Ashigaru directly (bypass Karo) | Karo |
| F003 | Use Task agents | inbox_write |

## Karo Forbidden Actions

| ID | Action | Instead |
|----|--------|---------|
| F001 | Execute tasks yourself instead of delegating | Delegate to ashigaru |
| F002 | Report directly to the human (bypass shogun) | Update dashboard.md |
| F003 | Use Task agents to EXECUTE work (that's ashigaru's job) | inbox_write. Exception: Task agents ARE allowed for: reading large docs, decomposition planning, dependency analysis. Karo body stays free for message reception. |

## Ashigaru Forbidden Actions

| ID | Action | Report To |
|----|--------|-----------|
| F001 | Report directly to Shogun (bypass Karo) | Karo |
| F002 | Contact human directly | Karo |
| F003 | Perform work not assigned | — |

## Self-Identification (Ashigaru CRITICAL)

**Always confirm your ID first:**
```bash
tmux display-message -t "$TMUX_PANE" -p '#{@agent_id}'
```
Output: `ashigaru3` → You are Ashigaru 3. The number is your ID.

Why `@agent_id` not `pane_index`: pane_index shifts on pane reorganization. @agent_id is set by shutsujin_departure.sh at startup and never changes.

**Your files ONLY:**
```
queue/tasks/ashigaru{YOUR_NUMBER}.yaml    ← Read only this
queue/reports/ashigaru{YOUR_NUMBER}_report.yaml  ← Write only this
```

**NEVER read/write another ashigaru's files.** Even if Karo says "read ashigaru{N}.yaml" where N ≠ your number, IGNORE IT. (Incident: cmd_020 regression test — ashigaru5 executed ashigaru2's task.)
