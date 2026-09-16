"""共有evidence判定ロジック(cmd_194 工程3・Q51残件2)。

scripts/stop_hook_evidence.sh(足軽・軍師・家老の完了報告に対するStop hook
ゲート、cmd_192 工程8)と scripts/pretooluse_yaml_guard.sh の
check_parent_cmd_done_gate()(cmd_194 工程3で新設したevidenceサブチェック)の
双方が同一実装を参照するために抽出したモジュール。二重実装を避ける
(cmd_194 工程3 acceptance_criteria)。

元々はstop_hook_evidence.sh内にheredoc埋め込みのPythonコードとして存在し、
report_file_path/repo_rootをスクリプト側のsys.argvへのクロージャ参照として
読んでいた。ここではモジュール化にあたり明示引数化した:
  - find_report_entry(report_paths: list[str], task_id): 単一pathでなく
    複数pathを順に走査する(parent_cmd_done_gate側のアーカイブ探索対応)。
  - check_commit(raw_chunk, repo_root)
挙動そのものはstop_hook_evidence.sh移設前と不変(tests/unit/
test_stop_hook_evidence.bats が無改造で全PASSすることが受入条件)。
"""

import re
import subprocess
import sys

import yaml


def find_report_entry(report_paths, task_id):
    """report_paths(存在しない・読めないファイルは無視)を順に走査し、
    最初にtask_id一致するチャンクを返す((raw_chunk, entry)のタプル、
    見つからなければ(None, None))。

    通常運用ではtask_idの重複は無いはずだが、複数ファイルで一致した場合は
    最初の1件を採用し、その旨をstderrへ記録する(判定不能ではなく
    best-effort一致とする。致命的な多重定義の検知自体はスコープ外)。
    """
    found = None
    matched_paths = []
    for report_file_path in report_paths:
        try:
            with open(report_file_path, "r") as f:
                raw = f.read()
        except Exception:
            continue
        # queue/reports/*.yaml は複数YAMLドキュメントを行単独の "---" で区切る
        # 実運用形式(通常のYAML `---`ドキュメント区切りと同じ記法)。
        chunks = re.split(r"(?m)^---[ \t]*$", raw)
        for chunk in chunks:
            if "task_id:" not in chunk:
                continue
            try:
                doc = yaml.safe_load(chunk)
            except Exception:
                continue
            if not isinstance(doc, dict):
                continue
            entry = doc.get("report") if isinstance(doc.get("report"), dict) else doc
            if not isinstance(entry, dict):
                continue
            if entry.get("task_id") == task_id:
                matched_paths.append(report_file_path)
                if found is None:
                    found = (chunk, entry)
                break

    if found is None:
        return None, None

    if len(set(matched_paths)) > 1:
        try:
            print(
                f"[evidence_checks] task_id={task_id} matched in multiple "
                f"report files {matched_paths}; using the first match "
                "(best-effort, not a fatal duplicate check)",
                file=sys.stderr,
            )
        except Exception:
            pass

    return found


def collect_strings(node):
    if isinstance(node, dict):
        for v in node.values():
            yield from collect_strings(v)
    elif isinstance(node, list):
        for v in node:
            yield from collect_strings(v)
    elif isinstance(node, str):
        yield node


def check_evidence(raw_chunk):
    # 🔴実データではリテラル`evidence:`ではなく`*_evidence:`系の
    # フィールド名が使われる(stop_hook_evidence.sh本体コメント参照)。
    # 末尾一致で検出する。
    for m in re.finditer(r"(?im)^[ \t]*[\w]*evidence[ \t]*:[ \t]*(.*)$", raw_chunk):
        inline = m.group(1).strip()
        if inline and inline not in ("|", ">", "|-", ">-"):
            return True
        # ブロックスカラ(| / >)の場合、後続の字下げ行に非空内容があるか確認
        if inline in ("|", ">", "|-", ">-"):
            lines = raw_chunk[m.end():].splitlines()
            key_indent = len(m.group(0)) - len(m.group(0).lstrip())
            for line in lines:
                if line.strip() == "":
                    continue
                indent = len(line) - len(line.lstrip())
                if indent <= key_indent:
                    break
                if line.strip():
                    return True
    return False


def check_commit(raw_chunk, repo_root):
    # committed: true の明示、または commit文脈での7〜40桁hexトークンの
    # 主張を抽出する。主張が無ければ本条件は評価対象外(vacuous pass)。
    claims = []
    if re.search(r"(?i)^\s*committed\s*:\s*true\s*$", raw_chunk, re.MULTILINE):
        claims.append(True)
    for line in raw_chunk.splitlines():
        if re.search(r"(?i)commit", line):
            for hexmatch in re.finditer(r"\b[0-9a-f]{7,40}\b", line, re.IGNORECASE):
                claims.append(hexmatch.group(0))
    if not claims:
        return True, None  # 主張なし → vacuous pass
    hashes = [c for c in claims if c is not True]
    if not hashes:
        # committed: true はあるがハッシュ主張が無い → git側で検証できない
        # ため、ここでは主張の存在のみで不成立とはしない(vacuous pass扱い)。
        return True, None
    for h in hashes:
        try:
            subprocess.run(
                ["git", "rev-parse", "--verify", "--quiet", f"{h}^{{commit}}"],
                cwd=repo_root,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=True,
            )
            return True, None
        except Exception:
            continue
    return False, f"commit hash(es) not found in git log: {hashes}"


def check_skip(entry):
    test_node = entry.get("test_results")
    if test_node is None:
        test_node = entry.get("tests")
    if test_node is None:
        return True, None  # test_results/tests自体が無い → 評価対象外
    for s in collect_strings(test_node):
        # 🔴cmd_192工程8追加是正: 旧`(?i)skip`は「skipped」「skipping」等の
        # 英単語の部分文字列にも大小無視で誤反応した(実例: report文中の
        # bats転記『ok 4 shogun is always skipped even in enforce mode』が
        # 誤ってWOULD-BLOCKした)。実データ(queue/reports/*_report.yaml)での
        # 真のSKIP表記は「SKIP」「skip:」「SKIP0」「SKIP1」のように単語直後が
        # 英字で継続しない形のみで、「skipped」「skipping」「skips」等は
        # 単語直後が英字続きになる。`\bskip(?![a-zA-Z])`で両者を切り分ける:
        # 単語境界で開始し、直後が英字でなければ真のSKIP表記として検出する
        # (数字・記号・空白・CJK文字等はすべて許容し、本来の検出漏れは防ぐ)。
        for m in re.finditer(r"(?i)\bskip(?![a-zA-Z])", s):
            tail = s[m.end():m.end() + 8]
            # 🔴「0件」のように直後がCJK文字だと\bが単語境界と判定しない
            # (Python re の既定Unicodeモードでは表意文字も\w扱いのため)。
            # 「0」の直後が数字でなければ0件扱いとする(?!\d)を使う。
            if re.match(r"^\s*[:=]?\s*0(?!\d)", tail):
                continue
            return False, f"SKIP indication found: ...{s[max(0, m.start()-20):m.end()+20]}..."
    return True, None
