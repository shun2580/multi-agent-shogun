---
name: codd-greenfield
description: |
  Bootstrap a new CoDD project from natural-language description and run the full greenfield pipeline: codd init → generate (all waves, HITL-gated) → validate → scan → plan derive → implement → assemble → verify. Use when the user describes a new project they want to build ("〇〇というWebアプリを作りたい", "新規プロジェクトを始めたい", "〇〇を開発して"). NOT for modifying existing CoDD projects — use /codd-evolve for that.
---

# CoDD Greenfield — New Project Full Pipeline

Accept a natural-language project description and drive the complete CoDD greenfield pipeline from initialization to a buildable, verified project. The user describes what they want; this skill handles every CoDD command in the correct order.

## Environment (この環境固有の設定)

| 項目 | 値 |
|------|----|
| codd バイナリ | `/home/nishikawa/.local/bin/codd`（PATH 経由で `codd` として呼び出し可） |
| codd バージョン | 2.19.0 |
| ai_command デフォルト | `claude --print --model claude-sonnet-5-5 --tools ""` |
| プロジェクト配置先 | `/home/nishikawa/projects/<project-name>/`（殿が別途指定しない限り） |

## When to Use

- User describes a **new project** they want to build from scratch
- Trigger phrases:
  - 「〇〇というWebアプリを作りたい」
  - 「〇〇を新規開発して」
  - 「新しいプロジェクトを始めたい」
  - 「〇〇のCLIツールを作って」
  - 「〇〇のAPIサーバーを作りたい」
- The project directory does NOT yet have a `codd/` directory

Do NOT use this for:
- Modifying an existing CoDD project → use `/codd-evolve`
- Reverse-engineering existing code without CoDD → use `codd extract` then `codd restore`
- Bug fixes only → use `codd fix`

## Role Separation

| Layer | Who decides | What |
|-------|-------------|------|
| Project description | **User** | What to build, in natural language |
| Tech stack | **User** (with skill's guidance) | Language, framework, constraints |
| Requirements writing | **This skill** | Converts user description to `requirements/*.md` |
| Wave generation | **This skill + CoDD** | `codd generate` per wave |
| Wave review | **User (HITL gate)** | Approve each wave before proceeding |
| Implementation task derivation | **CoDD CLI** | `codd plan derive` |
| Code generation | **CoDD CLI** | `codd implement run` |
| Assembly | **CoDD CLI** | `codd assemble` |
| Final verification | **This skill** | `codd verify` must reach red 0 |
| Commit approval | **User** | Never auto-commit |

## Full Pipeline

```
Phase 1: Init
  Step 1 — Gather project info (ask user once)
  Step 2 — Write requirements doc
  Step 3 — codd init

Phase 2: Generate (repeat per wave with HITL gate)
  Step 4 — codd generate --wave N
  Step 5 — codd validate --path .
  Step 6 — codd scan --path .
  Step 7 — HITL: user reviews wave, approves next wave

Phase 3: Implement
  Step 8 — codd plan derive
  Step 9 — codd plan approve
  Step 10 — codd implement run

Phase 4: Assemble & Verify
  Step 11 — codd assemble
  Step 12 — codd verify
  Step 13 — codd propagate
  Step 14 — Report to user
```

---

## Detailed Steps

### Phase 1: Init

#### Step 1 — Gather project info

Ask the user **once** for all required inputs. Do not ask piecemeal.

Required:
- **Project name**: default to snake_case of what they described
- **Primary language**: `python` / `typescript` / `javascript` / `go` / `java`
- **Project destination**: default to `/home/nishikawa/projects/<project-name>/`

Optional (ask only if not inferable):
- Framework preferences (e.g., Next.js, FastAPI, Gin)
- Key constraints (auth, DB type, external APIs)
- Existing requirements doc to import

If the user's initial message already answers all of these, skip the question and proceed.

#### Step 2 — Write requirements doc

Before running `codd init`, write `requirements.md` in a temporary location (e.g., `/tmp/<project-name>_requirements.md`).

Requirements doc format:
```markdown
# <Project Name> Requirements

## Overview
<1–3 sentences describing what the project does and for whom>

## Core Features
- <Feature 1>
- <Feature 2>
- ...

## Non-Functional Requirements
- Language: <language>
- Framework: <framework if specified>
- <Any constraints from user>

## Out of Scope
- <Anything explicitly excluded>
```

Write concisely from the user's description. Do not invent features not mentioned.

#### Step 3 — codd init

Create the project directory, then run:

```bash
mkdir -p /home/nishikawa/projects/<project-name>
cd /home/nishikawa/projects/<project-name>
codd init \
  --project-name "<project-name>" \
  --language <language> \
  --requirements /tmp/<project-name>_requirements.md \
  --dest .
```

Verify the skeleton was created:
- `codd/codd.yaml` ✅
- `codd/scan/` ✅
- `docs/requirements/requirements.md` (with CoDD frontmatter) ✅

If `codd init` fails, diagnose before continuing.

---

### Phase 2: Generate (Wave Loop)

Since codd v0.2.0a4, `codd generate` auto-generates `wave_config` from requirements. **No need to run `codd plan --init` manually.**

#### Step 4 — Generate wave N

Start from wave 2 (wave 1 is requirement-only artifacts, auto-handled):

```bash
codd generate --wave 2 --path .
```

After the first wave succeeds, check total wave count and loop:
```bash
codd plan --waves --path .   # → e.g., "3"
```

Then for each subsequent wave:
```bash
codd generate --wave 3 --path .
# ... up to total wave count
```

#### Step 5 — Validate after each wave

```bash
codd validate --path .
```

If validation errors appear:
- `missing_field` / `missing_frontmatter`: open the file, add `node_id` and `type` to frontmatter
- `invalid_reference` / `dangling_depends_on`: fix the `depends_on` references
- `circular_dependency`: remove the back-edge in the dependency chain
- Fix → re-run `codd validate --path .` → confirm clean before continuing

Do NOT proceed to the next wave while validation is failing.

#### Step 6 — Scan after each wave

```bash
codd scan --path .
```

#### Step 7 — HITL gate (mandatory between waves)

After generating and validating each wave, **pause and ask the user**:

```
Wave N の設計書を生成しました。確認をお願いします。

生成されたファイル:
- docs/design/<doc1>.md
- docs/design/<doc2>.md

問題なければ「Wave N+1 に進んでください」とお伝えください。
修正が必要な場合はその内容をお知らせください。
```

If the user requests changes:
1. Edit the generated design doc directly
2. Re-run `codd validate --path .` and `codd scan --path .`
3. Request approval again before advancing

If this is the final wave, skip the "next wave" message and move to Phase 3.

---

### Phase 3: Implement

#### Step 8 — Derive implementation tasks

```bash
codd plan derive --path .
```

Show the user a summary of derived tasks.

#### Step 9 — Approve tasks

```bash
codd plan approve --path .
```

#### Step 10 — Run implementation

```bash
codd implement run --path .
```

For large projects, use chunked execution:
```bash
codd implement run --path . --chunk-size 5
```

If `codd implement run` fails mid-way:
```bash
codd implement resume --path .
```

---

### Phase 4: Assemble & Verify

#### Step 11 — Assemble

```bash
codd assemble --path .
```

Verify expected files are generated under `src/` (or configured output dir).

#### Step 12 — Verify coherence

```bash
codd verify --path .
```

**Must reach red 0.** If red > 0:
1. First retry: `codd fix --path .`
2. If still red: surface failing node, classify cause, ask user
3. Max 3 retries. After 3 failures, STOP and report with diagnostics.

#### Step 13 — Propagate

```bash
codd propagate --path .
```

Catches final cross-doc drift between implemented source and design.

---

### Step 14 — Final Report

```
✅ プロジェクト生成完了

プロジェクト: <project-name>
場所: /home/nishikawa/projects/<project-name>/

生成内容:
- 要件書: docs/requirements/requirements.md
- 設計書: docs/design/ (N ファイル)
- ソース: src/ (N ファイル)

CoDD 状態:
- verify: red 0 ✅
- propagate: drift 0 ✅

推奨コミットメッセージ:
  feat: initial CoDD greenfield generation for <project-name>

次のステップ:
1. src/ のコードを確認してください
2. 問題なければコミットを承認してください
3. 以降の機能追加は「〇〇追加して」と話しかけるだけで /codd-evolve が対応します
```

Do NOT commit unless the user explicitly approves.

---

## Absolute Constraints

1. **Never run the next wave without HITL approval.** One wave at a time.
2. **Never proceed with failing `codd validate`.** Fix frontmatter errors first.
3. **Never invent features** not mentioned in the user's description. Write what was asked.
4. **Never commit without user approval.**
5. **Never skip `codd verify`.** Red > 0 means the project is not done.
6. **Never run `codd init` if `codd/` already exists.** Inspect existing setup instead.

## Stop-and-Ask Gates

Stop and ask the user only when:

1. **Tech stack is ambiguous**: language or framework cannot be inferred from the description
2. **Wave content drifted from requirements**: generated design covers features not described
3. **verify red > 0 after 3 retries**: surface diagnostics, ask how to proceed
4. **Scope is unclear**: "make a web app" with no further detail — ask one clarifying question

## Guardrails

- Run all `codd` commands from the project root
- Use `codd` command, not `python -m codd.cli`
- Do not manually edit generated design docs unless the user requests changes at a HITL gate
- If the user bundles multiple unrelated projects ("make a todo app AND a weather app"), handle one at a time
- Preserve all frontmatter exactly — only modify doc bodies when making user-requested corrections

## Troubleshooting

| Error | Action |
|-------|--------|
| `codd/ not found` | Run `codd init` first |
| `command not found: codd` | Check PATH: `/home/nishikawa/.local/bin/codd` |
| Wave generation produces empty files | Check requirements.md has CoDD frontmatter (`node_id`, `type: requirement`) |
| `codd validate` fails repeatedly | Fix reported file's frontmatter; re-run |
| `codd implement run` hangs | Use `--chunk-size 3` and `--timeout-per-chunk 300` |
| `codd assemble` produces no files | Verify `src/generated/sprint_N/` directories exist after implement |
| `codd verify` red > 0 after 3 retries | STOP, report which node is red, ask user |

## Handoff to codd-evolve

Once this skill completes, all subsequent modifications use `/codd-evolve`:

```
✅ 初期生成完了後の修正は /codd-evolve が担当します。

例:
  殿: 「ログアウト機能を追加して」→ /codd-evolve が自動実行
  殿: 「ユーザー一覧画面を変更して」→ /codd-evolve が自動実行
```

The handoff is seamless — the user simply describes the change in natural language.
