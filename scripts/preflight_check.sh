#!/usr/bin/env bash
# preflight_check.sh — 起動前依存検査
# exit 0: 正常 (警告のみの欠落は 0)
# exit 1: 致命依存欠落 → 呼び出し側が exit 1 で起動中止
# exit 2: プリフライト内部エラー (OS判定不能等)

# Testing guard: __PREFLIGHT_TESTING__=1 の時は set -euo pipefail を無効化
if [ "${__PREFLIGHT_TESTING__:-}" != "1" ]; then
    set -euo pipefail
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# seam: command -v ラッパ (bats で export -f してオーバーライド可)
dep_present() { command -v "$1" &>/dev/null; }

# seam: .venv python の import 検査ラッパ
py_module_present() {
    local module="$1"
    local venv_py="${SCRIPT_DIR}/.venv/bin/python3"
    [ -f "$venv_py" ] && "$venv_py" -c "import $module" 2>/dev/null
}

# seam: .venv/bin/python3 存在確認
venv_python_present() {
    [ -f "${SCRIPT_DIR}/.venv/bin/python3" ]
}

# seam: OS 判定して watch backend を検査
check_watch_backend() {
    local os
    os=$(uname -s)
    case "$os" in
        Darwin) dep_present fswatch ;;
        Linux)  dep_present inotifywait ;;
        *)
            echo -e "\033[1;31m【PREFLIGHT ERROR】\033[0m OS 判定不能: $os" >&2
            return 2
            ;;
    esac
}

run_preflight() {
    local fatal=0
    local os
    os=$(uname -s 2>/dev/null || echo "")

    # ── 致命: watch backend ──
    if ! check_watch_backend; then
        local rc=$?
        if [ "$rc" -eq 2 ]; then
            return 2
        fi
        if [ "$os" = "Darwin" ]; then
            echo -e "\033[1;31m【PREFLIGHT ERROR】\033[0m fswatch が見つかりません"
            echo "  導入: brew install fswatch"
        else
            echo -e "\033[1;31m【PREFLIGHT ERROR】\033[0m inotifywait が見つかりません"
            echo "  導入: sudo apt install inotify-tools   (Ubuntu/Debian)"
            echo "         sudo dnf install inotify-tools   (Fedora/RHEL)"
        fi
        fatal=1
    fi

    # ── 致命: tmux ──
    if ! dep_present tmux; then
        echo -e "\033[1;31m【PREFLIGHT ERROR】\033[0m tmux が見つかりません"
        echo "  導入: sudo apt install tmux   (Ubuntu/Debian)"
        echo "         sudo dnf install tmux   (Fedora/RHEL)"
        echo "         brew install tmux        (macOS)"
        fatal=1
    fi

    # ── 致命: system python3 ──
    if ! dep_present python3; then
        echo -e "\033[1;31m【PREFLIGHT ERROR】\033[0m python3 が見つかりません"
        echo "  導入: sudo apt install python3   (Ubuntu/Debian)"
        echo "         sudo dnf install python3   (Fedora/RHEL)"
        echo "         brew install python3        (macOS)"
        fatal=1
    fi

    # ── 致命: .venv/bin/python3 ──
    if ! venv_python_present; then
        echo -e "\033[1;31m【PREFLIGHT ERROR】\033[0m .venv/bin/python3 が見つかりません"
        echo "  修復: python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"
        fatal=1
    fi

    # ── 警告のみ: PyYAML ──
    if ! py_module_present yaml; then
        echo -e "\033[1;33m【PREFLIGHT WARN】\033[0m PyYAML (.venv) が import できません"
        echo "  修復: .venv/bin/pip install pyyaml"
    fi

    # ── 任意: flock ──
    if ! dep_present flock; then
        echo -e "\033[0;36m【PREFLIGHT INFO】\033[0m flock が見つかりません (任意)"
        echo "  導入: sudo apt install util-linux   (Ubuntu/Debian)"
    fi

    # ── 任意: pgrep ──
    if ! dep_present pgrep; then
        echo -e "\033[0;36m【PREFLIGHT INFO】\033[0m pgrep が見つかりません (任意)"
        echo "  導入: sudo apt install procps   (Ubuntu/Debian)"
    fi

    # 致命欠落があれば ntfy (best-effort)
    if [ "$fatal" -ne 0 ] && [ -f "${SCRIPT_DIR}/scripts/ntfy.sh" ]; then
        bash "${SCRIPT_DIR}/scripts/ntfy.sh" "🚨 起動失敗 — 必須依存が欠落。ターミナルを確認してください。" 2>/dev/null || true
    fi

    # ── 警告のみ: OpenRouter API キー確認 ──
    settings_yaml="${SCRIPT_DIR}/config/settings.yaml"
    if grep -q "openrouter/" "$settings_yaml" 2>/dev/null; then
        if [ -z "${OPENROUTER_API_KEY:-}" ] && [ ! -f "${HOME}/.opencode/auth.json" ]; then
            echo -e "\033[1;33m【PREFLIGHT WARN】\033[0m OpenRouter 対応足軽が設定されていますが OPENROUTER_API_KEY が未設定です"
            echo "  設定方法: export OPENROUTER_API_KEY=<your_key> を起動シェルに追加"
            echo "         または: opencode auth login openrouter"
            echo "  ※ OPENROUTER_API_KEY が無い場合、当該足軽 (OpenCode+OpenRouter) は動作しません"
        fi
    fi

    return "$fatal"
}

if [ "${__PREFLIGHT_TESTING__:-}" != "1" ]; then
    run_preflight
fi
