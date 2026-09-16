"""引用符内非実行文字列マスキング共有ロジック(cmd_194 工程6'(a)・補遺2)。

scripts/pretooluse_git_push_block.sh(cmd_194 工程5で新設)と
scripts/pretooluse_reversibility_check.sh(cmd_194 工程6'で追加適用)の
双方が同一実装を参照するために抽出したモジュール(lib/evidence_checks.py
と同型、二重実装を避ける)。

実行される経路(bash -c/sh -c/evalの引数)の文字列は保護したまま、
実行されない単なるデータ引数(echo/grep等の引数文字列)内の"git push"相当
部分のみを同じ文字数の#列へ置換する。挙動はpretooluse_git_push_block.sh
移設前と不変(tests/unit/test_pretooluse_git_push_block.bats が無改造で
全PASSすることが受入条件)。
"""

import re

GIT_PUSH_MASK_RE = re.compile(r"\bgit\s+push\b")

# 引用符・シェル境界(呼出し元のSPLIT_RE等と同一文字集合)・語を1回の左から
# 右への走査で排他的にトークン化する(先にsplitしてしまうと、分割文字自体が
# 引用符内に現れた場合に誤分割するため、必ずsplitより前に処理する)。
QUOTE_MASK_TOKEN_RE = re.compile(
    r"(?P<boundary>\n|;|&&|\|\||\$\(|\)|`)"
    r"|(?P<dquote>\"(?:\\.|[^\"\\])*\")"
    r"|(?P<squote>'[^']*')"
    r"|(?P<word>[^\s;&|()`\"'\n]+)"
    r"|(?P<other>[\s\S])"
)

# -cが実行の引数として意味を持つのはシェル本体を直接起動した場合のみ
# (evalは-c無しで引数を直接評価するため、eval用の判定は別条件で行う)。
SHELL_C_BASENAMES = {"bash", "sh", "zsh", "dash", "ksh"}


def mask_quoted_nonexec_strings(cmd):
    out = []
    current_sink = None
    dash_c_armed = False
    for tok in QUOTE_MASK_TOKEN_RE.finditer(cmd):
        kind = tok.lastgroup
        text = tok.group()
        if kind == "boundary":
            current_sink = None
            dash_c_armed = False
            out.append(text)
        elif kind == "word":
            if current_sink is None:
                current_sink = text.rsplit("/", 1)[-1]
            if text == "-c" and current_sink in SHELL_C_BASENAMES:
                dash_c_armed = True
            out.append(text)
        elif kind in ("dquote", "squote"):
            if dash_c_armed or current_sink == "eval":
                # 実行される経路(bash -c/sh -c/evalの引数)の文字列は保護
                # したまま保持する(検知力を落とさないため)。
                dash_c_armed = False
                out.append(text)
            else:
                # 実行されない単なるデータ引数: 引用符範囲内でのみ
                # git push相当部分を同じ文字数の#列へ置換する(引用符の
                # 外側・非マッチ部分は変更しない)。
                out.append(GIT_PUSH_MASK_RE.sub(lambda m: "#" * len(m.group(0)), text))
        else:
            out.append(text)
    return "".join(out)
