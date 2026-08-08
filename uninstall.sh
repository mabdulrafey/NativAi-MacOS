#!/bin/bash
#
# NativAI uninstaller
#
# Removes NativAI and, optionally, Ollama and every downloaded model.
#
# Design notes:
#
#   * Models are the big item — typically tens of gigabytes (22 GB on the
#     development machine). That is the whole reason this script exists: dragging
#     the .app to the Trash reclaims ~10 MB and silently leaves the rest behind
#     forever, in a hidden directory most users will never find.
#
#   * Nothing is deleted without confirmation, and the exact byte count is shown
#     first. Removing Ollama is asked about separately, because a user may well
#     have installed it before NativAI and still want it.
#
#   * `sudo` is used only for paths that genuinely require it (/Applications,
#     /usr/local/bin) and is requested explicitly, once, with the reason stated.
#
#   * Every path is a literal — no globbing into rm -rf, no variables that could
#     expand to empty and turn a delete into `rm -rf /`. Each removal is guarded
#     by an existence check on a fully-qualified path.

set -uo pipefail

GRN='\033[0;32m'; YLW='\033[0;33m'; RED='\033[0;31m'; BLD='\033[1m'; RST='\033[0m'

APP_PATH="/Applications/NativAI.app"
SUPPORT_DIR="${HOME}/Library/Application Support/NativAI"
CACHES=(
    "${HOME}/Library/Caches/com.nativai.app"
    "${HOME}/Library/Caches/mar.NativAI"
    "${HOME}/Library/Caches/NativAI"
)
PREFS=(
    "${HOME}/Library/Preferences/com.nativai.app.plist"
    "${HOME}/Library/Preferences/mar.NativAI.plist"
    "${HOME}/Library/Preferences/NativAI.plist"
)
SAVED_STATES=(
    "${HOME}/Library/Saved Application State/com.nativai.app.savedState"
    "${HOME}/Library/Saved Application State/mar.NativAI.savedState"
    "${HOME}/Library/Saved Application State/NativAI.savedState"
)
OLLAMA_HOME="${HOME}/.ollama"

# Where models actually live.
#
# `OLLAMA_MODELS` is a documented Ollama setting, and relocating the model store
# is common on Macs with a small internal SSD (an external drive, or a second
# volume). Ignoring it produced a silent, expensive failure: the user answers
# "yes, delete the models", the script reports success, and tens of gigabytes are
# still on disk in a directory it never looked at.
#
# Checked in the same precedence order Ollama itself uses — explicit environment
# variable, then the launchd environment (which is what a Homebrew-managed
# service actually reads), then the default.
MODELS_DIR="${OLLAMA_MODELS:-}"
if [[ -z "${MODELS_DIR}" ]]; then
    MODELS_DIR="$(launchctl getenv OLLAMA_MODELS 2>/dev/null || true)"
fi
if [[ -z "${MODELS_DIR}" ]]; then
    MODELS_DIR="${OLLAMA_HOME}/models"
fi
LAUNCH_AGENT="${HOME}/Library/LaunchAgents/homebrew.mxcl.ollama.plist"
RECEIPTS_PREFIX="NativAI"

echo ""
echo -e "${BLD}NativAI Uninstaller${RST}"
echo "───────────────────────────────────────────────"

# ── Report what exists, with sizes, before touching anything ────────────────
human_size() {
    [[ -e "$1" ]] && du -sh "$1" 2>/dev/null | awk '{print $1}' || echo "—"
}

echo ""
echo "Found on this Mac:"
[[ -d "${APP_PATH}"    ]] && echo "  • NativAI.app                 $(human_size "${APP_PATH}")"
[[ -d "${SUPPORT_DIR}" ]] && echo "  • Chats & memory              $(human_size "${SUPPORT_DIR}")"
[[ -d "${MODELS_DIR}"  ]] && echo "  • Ollama models               $(human_size "${MODELS_DIR}")"
OLLAMA_BIN=""
for candidate in /opt/homebrew/bin/ollama /usr/local/bin/ollama; do
    if [[ -x "${candidate}" ]]; then OLLAMA_BIN="${candidate}"; break; fi
done
[[ -n "${OLLAMA_BIN}"     ]] && echo "  • Ollama binary               ${OLLAMA_BIN}"
[[ -d "/Applications/Ollama.app" ]] && echo "  • Ollama.app                  $(human_size /Applications/Ollama.app)"
echo ""

# ── Consent ────────────────────────────────────────────────────────────────
read -r -p "Remove NativAI (app, chats, memory, preferences)? [y/N] " REPLY_APP
REMOVE_APP=false
[[ "${REPLY_APP}" =~ ^[Yy]$ ]] && REMOVE_APP=true

REMOVE_OLLAMA=false
if [[ -n "${OLLAMA_BIN}" || -d "${OLLAMA_HOME}" ]]; then
    echo ""
    echo -e "${YLW}Ollama is a separate tool that NativAI uses.${RST}"
    echo "You may have installed it yourself, or use it outside NativAI."
    read -r -p "Also remove Ollama itself? [y/N] " REPLY_OLLAMA
    [[ "${REPLY_OLLAMA}" =~ ^[Yy]$ ]] && REMOVE_OLLAMA=true
fi

# Asked independently of the Ollama question.
#
# Previously this prompt was nested inside the "remove Ollama?" block, so
# declining Ollama skipped it entirely and left the models — which are the single
# largest thing on disk — with no way to remove them. Keeping Ollama and deleting
# its downloads is also a perfectly reasonable combination.
REMOVE_MODELS=false
if [[ -d "${MODELS_DIR}" ]]; then
    echo ""
    echo -e "${RED}${BLD}Downloaded models: $(human_size "${MODELS_DIR}")${RST}"
    echo "  location: ${MODELS_DIR}"
    echo "Deleting these frees the most space. They must be re-downloaded to use again."
    read -r -p "Delete all downloaded models? [y/N] " REPLY_MODELS
    [[ "${REPLY_MODELS}" =~ ^[Yy]$ ]] && REMOVE_MODELS=true
fi

if [[ "${REMOVE_APP}" == false && "${REMOVE_OLLAMA}" == false && "${REMOVE_MODELS}" == false ]]; then
    echo ""
    echo "Nothing selected. No changes made."
    exit 0
fi

# ── Stop running processes first ───────────────────────────────────────────
# Deleting a binary out from under a running process leaves an orphan holding
# gigabytes of RAM until reboot.
echo ""
echo "Stopping running processes…"
pkill -u "$(id -u)" -x NativAI 2>/dev/null && echo "  ✔ Quit NativAI" || true

if [[ "${REMOVE_OLLAMA}" == true || "${REMOVE_MODELS}" == true ]]; then
    for brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [[ -x "${brew}" ]]; then
            "${brew}" services stop ollama >/dev/null 2>&1 && echo "  ✔ Stopped Ollama service" || true
            break
        fi
    done
    # -u limits this to the current user's processes: on a shared machine another
    # user's Ollama is none of our business.
    pkill -u "$(id -u)" -x ollama 2>/dev/null && echo "  ✔ Stopped Ollama server" || true
    pkill -u "$(id -u)" -f "ollama runner" 2>/dev/null && echo "  ✔ Stopped model runner" || true
    sleep 1
fi

# ── Determine whether sudo is needed, and ask once ─────────────────────────
NEEDS_SUDO=false
[[ "${REMOVE_APP}" == true && -d "${APP_PATH}" && ! -w "/Applications" ]] && NEEDS_SUDO=true
[[ "${REMOVE_OLLAMA}" == true && -n "${OLLAMA_BIN}" && ! -w "$(dirname "${OLLAMA_BIN}")" ]] && NEEDS_SUDO=true
[[ "${REMOVE_OLLAMA}" == true && -d "/Applications/Ollama.app" ]] && NEEDS_SUDO=true

if [[ "${NEEDS_SUDO}" == true ]]; then
    echo ""
    echo "Administrator access is needed to remove items from /Applications."
    sudo -v || { echo -e "${RED}Could not obtain administrator access — aborting.${RST}"; exit 1; }
fi

# Removes a path, using sudo only when the parent isn't writable.
remove_path() {
    local target="$1" label="$2"
    [[ -e "${target}" ]] || return 0
    if [[ -w "$(dirname "${target}")" ]]; then
        rm -rf "${target}"
    else
        sudo rm -rf "${target}"
    fi
    if [[ -e "${target}" ]]; then
        echo -e "  ${RED}✖ Failed: ${label}${RST}"
    else
        echo "  ✔ Removed ${label}"
    fi
}

# ── NativAI ────────────────────────────────────────────────────────────────
if [[ "${REMOVE_APP}" == true ]]; then
    echo ""
    echo "Removing NativAI…"
    remove_path "${APP_PATH}" "NativAI.app"
    remove_path "${SUPPORT_DIR}" "chats & memory"
    for cdir in "${CACHES[@]}"; do
        remove_path "${cdir}" "caches ($(basename "${cdir}"))"
    done
    for sdir in "${SAVED_STATES[@]}"; do
        remove_path "${sdir}" "saved window state ($(basename "${sdir}"))"
    done
    for plist in "${PREFS[@]}"; do
        remove_path "${plist}" "$(basename "${plist}")"
    done
    # Clear the in-memory preference cache too, otherwise a reinstall inherits
    # the old settings from cfprefsd even though the file is gone.
    defaults delete com.nativai.app >/dev/null 2>&1 || true
    defaults delete mar.NativAI >/dev/null 2>&1 || true
    defaults delete NativAI >/dev/null 2>&1 || true
    killall cfprefsd >/dev/null 2>&1 || true

    # Forget the installer receipt so a future .pkg install isn't treated as an
    # upgrade of something that no longer exists.
    while read -r receipt; do
        [[ -n "${receipt}" ]] || continue
        sudo pkgutil --forget "${receipt}" >/dev/null 2>&1 \
            && echo "  ✔ Forgot receipt ${receipt}" || true
    done < <(pkgutil --pkgs 2>/dev/null | grep -iE "nativai|com.nativai" || true)
fi

# ── Models ─────────────────────────────────────────────────────────────────
# Done before removing Ollama itself, since the path is independent of it.
if [[ "${REMOVE_MODELS}" == true ]]; then
    echo ""
    echo "Deleting downloaded models…"
    remove_path "${MODELS_DIR}" "Ollama LLM models"
    remove_path "${SUPPORT_DIR}/CoreMLModels" "CoreML Stable Diffusion models"
    remove_path "${HOME}/Library/Caches/CoreML" "CoreML model cache"
    remove_path "${HOME}/Library/Caches/com.apple.metal" "Metal GPU shader cache"

    if [[ "${REMOVE_OLLAMA}" == true ]]; then
        remove_path "${OLLAMA_HOME}" "Ollama data directory"
    fi
fi

# ── Ollama ─────────────────────────────────────────────────────────────────
if [[ "${REMOVE_OLLAMA}" == true ]]; then
    echo ""
    echo "Removing Ollama…"

    # Prefer the package manager that installed it, so its own bookkeeping stays
    # consistent rather than being left with a dangling formula.
    UNINSTALLED_VIA_BREW=false
    for brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [[ -x "${brew}" ]] && "${brew}" list ollama >/dev/null 2>&1; then
            "${brew}" uninstall --force ollama >/dev/null 2>&1 \
                && { echo "  ✔ Uninstalled via Homebrew"; UNINSTALLED_VIA_BREW=true; }
            break
        fi
    done

    if [[ "${UNINSTALLED_VIA_BREW}" == false && -n "${OLLAMA_BIN}" ]]; then
        remove_path "${OLLAMA_BIN}" "ollama binary"
    fi

    remove_path "/Applications/Ollama.app" "Ollama.app"
    remove_path "${LAUNCH_AGENT}" "launch agent"
    remove_path "${HOME}/Library/Application Support/Ollama" "Ollama app support"
    remove_path "${HOME}/Library/Caches/ollama" "Ollama caches"
fi

echo ""
echo -e "${GRN}${BLD}Done.${RST}"
if [[ "${REMOVE_MODELS}" == false && -d "${MODELS_DIR}" ]]; then
    echo ""
    echo -e "${YLW}Note:${RST} downloaded models were kept at ${MODELS_DIR}"
    echo "      ($(human_size "${MODELS_DIR}")). Delete that folder to reclaim the space."
fi
echo ""
