#!/usr/bin/env bash
# kingsland-setup — idempotent macOS dev bootstrap
# Uso:
#   curl -fsSL https://kingsland.network/setup.sh | bash
#   # ou, para partes interativas (chsh/sudo):
#   curl -fsSL https://kingsland.network/setup.sh -o /tmp/setup.sh && bash /tmp/setup.sh

set -uo pipefail

# ============================================================
# Cores & helpers de UI
# ============================================================
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_BLUE=$'\033[1;34m'
  C_CYAN=$'\033[1;36m'
  C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'
  C_RED=$'\033[1;31m'
  C_MAGENTA=$'\033[1;35m'
else
  C_RESET="" C_BOLD="" C_DIM="" C_BLUE="" C_CYAN="" C_GREEN="" C_YELLOW="" C_RED="" C_MAGENTA=""
fi

ARROW="==>"

header()  { printf "\n${C_BLUE}${ARROW}${C_RESET} ${C_BOLD}%s${C_RESET}\n" "$*"; }
sub()     { printf "${C_CYAN}${ARROW}${C_RESET} %s\n" "$*"; }
info()    { printf "    %s\n" "$*"; }
ok_line() { printf "${C_GREEN}✓${C_RESET} %s\n" "$*"; }
warn()    { printf "${C_YELLOW}!${C_RESET} %s\n" "$*"; }
err()     { printf "${C_RED}✗${C_RESET} %s\n" "$*" >&2; }

# Renderiza uma linha de item de lista: "  [  1/ 37] name ........ STATUS"
# args: idx total name status color
render_item() {
  local idx=$1 total=$2 name=$3 status=$4 color=$5
  local pad_name=34
  local name_clean="$name"
  if (( ${#name_clean} > pad_name - 2 )); then
    name_clean="${name_clean:0:pad_name-3}…"
  fi
  local dots_len=$(( pad_name - ${#name_clean} ))
  local dots
  dots="$(printf '%*s' "$dots_len" '' | tr ' ' '.')"
  printf "  ${C_DIM}[%2d/%2d]${C_RESET} %s ${C_DIM}%s${C_RESET} ${color}%s${C_RESET}\n" \
    "$idx" "$total" "$name_clean" "$dots" "$status"
}

# Executa um comando, escondendo o output; em caso de falha, imprime o log.
run_quiet() {
  local logfile
  logfile="$(mktemp)"
  if "$@" >"$logfile" 2>&1; then
    rm -f "$logfile"
    return 0
  else
    local rc=$?
    echo
    err "Comando falhou: $*"
    sed 's/^/      /' "$logfile" >&2
    rm -f "$logfile"
    return $rc
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# ============================================================
# Sudo handling
# ============================================================
# Several steps require administrator privileges (Homebrew installer,
# brew casks, adding zsh to /etc/shells). The script must work both when
# invoked directly (`bash setup.sh`) and when piped (`curl ... | bash`),
# where stdin is the HTTP pipe and sudo cannot read the password from it.

SUDO_KEEPALIVE_PID=""

ensure_not_root() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    err "Do not run this script as root."
    err "Run it as your normal user — sudo will be requested when needed."
    err "Homebrew refuses to install under the root account."
    exit 1
  fi
}

# Prompt for the sudo password once (reading from /dev/tty when stdin is a
# pipe), then spawn a background keepalive to refresh the timestamp so long
# installs don't hit a password prompt mid-way.
ensure_sudo() {
  header "Administrator privileges"

  if ! have sudo; then
    err "sudo not found on PATH."
    exit 1
  fi

  if sudo -n true 2>/dev/null; then
    ok_line "sudo already authenticated (cached or passwordless)"
  else
    sub "Parts of this setup need administrator privileges"
    info "You will be prompted for your password once."
    if [[ -t 0 ]]; then
      sudo -v || { err "sudo authentication failed"; exit 1; }
    elif [[ -r /dev/tty ]]; then
      sudo -v </dev/tty || { err "sudo authentication failed"; exit 1; }
    else
      err "No terminal available to read the sudo password."
      err "Re-run without piping the script to bash:"
      err "  curl -fsSL https://kingsland.network/setup.sh -o /tmp/setup.sh && bash /tmp/setup.sh"
      exit 1
    fi
    ok_line "sudo authenticated"
  fi

  # Keepalive: refresh the sudo timestamp every 50s while the parent runs.
  ( while kill -0 $$ 2>/dev/null; do sudo -n true 2>/dev/null || true; sleep 50; done ) &
  SUDO_KEEPALIVE_PID=$!
  disown "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  trap cleanup_sudo EXIT INT TERM
}

cleanup_sudo() {
  if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    SUDO_KEEPALIVE_PID=""
  fi
}

# ============================================================
# Contadores p/ resumo final
# ============================================================
COUNT_INSTALLED=0
COUNT_SKIPPED=0
COUNT_FAILED=0
FAILED_ITEMS=()

# ============================================================
# Banner
# ============================================================
print_banner() {
  printf "\n"
  printf "${C_MAGENTA}"
  cat <<'BANNER'
   __   _                 __               __
  / /__(_)__  ___ ____ __/ /__ ____  ___/ /
 /  '_/ / _ \/ _ `(_-</ / _ `/ _ \/ _  /
/_/\_\/_/_//_/\_, /___/_/\_,_/_//_/\_,_/
             /___/   setup
BANNER
  printf "${C_RESET}"
  printf "${C_DIM}  https://kingsland.network/setup.sh${C_RESET}\n\n"
}

# ============================================================
# Preflight
# ============================================================
preflight() {
  header "Preflight"

  if [[ "$(uname -s)" != "Darwin" ]]; then
    err "Este script é para macOS."
    exit 1
  fi
  ok_line "macOS detectado ($(sw_vers -productVersion))"

  ARCH="$(uname -m)"
  if [[ "$ARCH" == "arm64" ]]; then
    BREW_PREFIX="/opt/homebrew"
    ok_line "Arquitetura Apple Silicon"
  else
    BREW_PREFIX="/usr/local"
    ok_line "Arquitetura Intel"
  fi

  if xcode-select -p >/dev/null 2>&1; then
    ok_line "Xcode Command Line Tools"
  else
    sub "Instalando Xcode Command Line Tools (pode abrir um diálogo)"
    xcode-select --install || true
    until xcode-select -p >/dev/null 2>&1; do
      sleep 5
    done
    ok_line "Xcode Command Line Tools instalado"
  fi
}

# ============================================================
# Homebrew
# ============================================================
install_homebrew() {
  header "Homebrew"
  if have brew; then
    ok_line "já instalado ($(brew --version | head -1))"
  else
    sub "Instalando Homebrew"
    NONINTERACTIVE=1 /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    ok_line "Homebrew instalado"
  fi
  if [[ -x "$BREW_PREFIX/bin/brew" ]]; then
    eval "$("$BREW_PREFIX/bin/brew" shellenv)"
  fi
}

# ============================================================
# Taps
# ============================================================
install_taps() {
  local taps=(oven-sh/bun)
  header "Taps"
  local current_taps
  current_taps="$(brew tap 2>/dev/null || true)"
  local i=0 total=${#taps[@]}
  for t in "${taps[@]}"; do
    i=$((i+1))
    if printf "%s\n" "$current_taps" | grep -qx "$t"; then
      render_item "$i" "$total" "$t" "skipped" "$C_DIM"
      COUNT_SKIPPED=$((COUNT_SKIPPED+1))
    else
      render_item "$i" "$total" "$t" "tapping…" "$C_YELLOW"
      if run_quiet brew tap "$t"; then
        tput cuu1 2>/dev/null && tput el 2>/dev/null || true
        render_item "$i" "$total" "$t" "tapped" "$C_GREEN"
        COUNT_INSTALLED=$((COUNT_INSTALLED+1))
      else
        render_item "$i" "$total" "$t" "failed" "$C_RED"
        COUNT_FAILED=$((COUNT_FAILED+1))
        FAILED_ITEMS+=("tap:$t")
      fi
    fi
  done
}

# ============================================================
# Formulas
# ============================================================
install_formulas() {
  local formulas=(
    apktool
    bat
    coreutils
    docker-compose
    eza
    fd
    ffmpeg
    fzf
    gcc
    gh
    git
    go
    golang-migrate
    htop
    jq
    libpaper
    libpq
    librsvg
    maven
    mkcert
    netpbm
    nvm
    openjdk@21
    oven-sh/bun/bun
    overmind
    pipx
    pkgconf
    ripgrep
    sshs
    starship
    tree
    webp
    wget
    yamllint
    zoxide
  )

  header "Formulas (${#formulas[@]})"
  local installed_list
  installed_list="$(brew list --formula -1 2>/dev/null || true)"

  local i=0 total=${#formulas[@]}
  for f in "${formulas[@]}"; do
    i=$((i+1))
    local short="${f##*/}"
    if printf "%s\n" "$installed_list" | grep -qx "$short"; then
      render_item "$i" "$total" "$short" "already installed" "$C_DIM"
      COUNT_SKIPPED=$((COUNT_SKIPPED+1))
      continue
    fi

    render_item "$i" "$total" "$short" "installing…" "$C_YELLOW"
    if run_quiet brew install "$f"; then
      tput cuu1 2>/dev/null && tput el 2>/dev/null || true
      render_item "$i" "$total" "$short" "installed" "$C_GREEN"
      COUNT_INSTALLED=$((COUNT_INSTALLED+1))
    else
      render_item "$i" "$total" "$short" "failed" "$C_RED"
      COUNT_FAILED=$((COUNT_FAILED+1))
      FAILED_ITEMS+=("formula:$f")
    fi
  done
}

# ============================================================
# Casks
# ============================================================
install_casks() {
  local casks=(
    android-commandlinetools
    android-platform-tools
    android-studio
    another-redis-desktop-manager
    block-goose
    inkscape
    ngrok
  )

  header "Casks (${#casks[@]})"
  local installed_list
  installed_list="$(brew list --cask -1 2>/dev/null || true)"

  local i=0 total=${#casks[@]}
  for c in "${casks[@]}"; do
    i=$((i+1))
    if printf "%s\n" "$installed_list" | grep -qx "$c"; then
      render_item "$i" "$total" "$c" "already installed" "$C_DIM"
      COUNT_SKIPPED=$((COUNT_SKIPPED+1))
      continue
    fi

    render_item "$i" "$total" "$c" "installing…" "$C_YELLOW"
    if run_quiet brew install --cask "$c"; then
      tput cuu1 2>/dev/null && tput el 2>/dev/null || true
      render_item "$i" "$total" "$c" "installed" "$C_GREEN"
      COUNT_INSTALLED=$((COUNT_INSTALLED+1))
    else
      render_item "$i" "$total" "$c" "failed" "$C_RED"
      COUNT_FAILED=$((COUNT_FAILED+1))
      FAILED_ITEMS+=("cask:$c")
    fi
  done
}

# ============================================================
# Post-install (fzf, shell)
# ============================================================
post_install() {
  header "Post-install"

  local fzf_installer="$BREW_PREFIX/opt/fzf/install"
  if [[ -x "$fzf_installer" ]]; then
    if [[ -f "$HOME/.fzf.zsh" ]]; then
      ok_line "fzf key-bindings já configurados"
    else
      sub "Configurando fzf key-bindings & completion"
      run_quiet "$fzf_installer" --key-bindings --completion --no-update-rc --no-bash --no-fish \
        && ok_line "fzf configurado" \
        || warn "fzf: falha ao configurar"
    fi
  fi

  local zsh_bin
  zsh_bin="$(command -v zsh || true)"
  if [[ -n "$zsh_bin" ]]; then
    if ! grep -qx "$zsh_bin" /etc/shells 2>/dev/null; then
      sub "Adding $zsh_bin to /etc/shells (sudo)"
      # -n: rely on the cached credentials from ensure_sudo; fail loudly
      # instead of hanging on a password prompt if the cache expired.
      if echo "$zsh_bin" | sudo -n tee -a /etc/shells >/dev/null; then
        ok_line "$zsh_bin added to /etc/shells"
      else
        warn "could not update /etc/shells (sudo cache expired?)"
      fi
    fi
    local current_shell
    current_shell="$(dscl . -read "/Users/$USER" UserShell 2>/dev/null | awk '{print $2}')"
    if [[ "$current_shell" == "$zsh_bin" ]]; then
      ok_line "zsh já é o shell padrão"
    else
      sub "Definindo zsh como shell padrão"
      chsh -s "$zsh_bin" && ok_line "shell padrão atualizado" \
        || warn "rode manualmente: chsh -s $zsh_bin"
    fi
  fi
}

# ============================================================
# .zshrc
# ============================================================
write_zshrc() {
  header "Dotfiles"
  local zshrc="$HOME/.zshrc"
  local tmp
  tmp="$(mktemp)"

  cat >"$tmp" <<'ZSHRC_EOF'
# ============================================================
# PATH (consolidated, deduped)
# ============================================================
export JAVA_HOME="/opt/homebrew/opt/openjdk@21"
export BUN_INSTALL="$HOME/.bun"
export PNPM_HOME="$HOME/Library/pnpm"
export ANDROID_SDK_ROOT="/opt/homebrew/share/android-commandlinetools"
export ANDROID_HOME="$ANDROID_SDK_ROOT"

path=(
  /opt/homebrew/opt/openjdk@21/bin
  /opt/homebrew/opt/libpq/bin
  $ANDROID_SDK_ROOT/platform-tools
  $ANDROID_SDK_ROOT/emulator
  $HOME/.sst/bin
  $HOME/.local/bin
  $BUN_INSTALL/bin
  $PNPM_HOME
  $path
)
typeset -U path PATH  # dedupe

# ============================================================
# History
# ============================================================
HISTFILE="$HOME/.zsh_history"
HISTSIZE=50000
SAVEHIST=50000
setopt HIST_IGNORE_ALL_DUPS     # drop older duplicates
setopt HIST_IGNORE_SPACE        # skip commands starting with space
setopt HIST_REDUCE_BLANKS       # trim whitespace
setopt SHARE_HISTORY            # share history across sessions
setopt EXTENDED_HISTORY         # save timestamps
setopt INC_APPEND_HISTORY       # append immediately

# ============================================================
# Zsh options (sane defaults, ex-OMZ)
# ============================================================
setopt AUTO_CD                  # cd by typing directory name
setopt AUTO_PUSHD               # cd pushes to stack
setopt PUSHD_IGNORE_DUPS        # no duplicates on stack
setopt PUSHD_SILENT             # don't print stack after pushd/popd
setopt INTERACTIVE_COMMENTS     # allow # comments in shell
setopt NO_BEEP                  # no beep on error
setopt PROMPT_SUBST             # allow $() in prompt

# ============================================================
# Completions (cached compinit for fast startup)
# ============================================================
fpath=(/opt/homebrew/share/zsh/site-functions $fpath)

autoload -Uz compinit
# Full compinit if dump is missing or older than 24h, else fast cached load
if [[ ! -f $HOME/.zcompdump || -n $HOME/.zcompdump(#qN.mh+24) ]]; then
  compinit
else
  compinit -C
fi

# Completion styling
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'   # case-insensitive
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"

# ============================================================
# Keybindings (emacs mode + history search)
# ============================================================
bindkey -e
autoload -Uz up-line-or-beginning-search down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search
bindkey '^[[A' up-line-or-beginning-search     # Up arrow
bindkey '^[[B' down-line-or-beginning-search   # Down arrow

# ============================================================
# NVM (lazy-load — shims for nvm/node/npm/npx)
# ============================================================
export NVM_DIR="$HOME/.nvm"
_load_nvm() {
  unset -f nvm node npm npx
  [ -s "/opt/homebrew/opt/nvm/nvm.sh" ] && \. "/opt/homebrew/opt/nvm/nvm.sh"
  [ -s "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm" ] && \. "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm"
  [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
}
nvm()  { _load_nvm; nvm "$@"; }
node() { _load_nvm; node "$@"; }
npm()  { _load_nvm; npm "$@"; }
npx()  { _load_nvm; npx "$@"; }

# ============================================================
# Modern tools
# ============================================================
# Starship prompt
eval "$(starship init zsh)"

# zoxide — smarter cd (use `z <partial>`, e.g. `z govhub`)
eval "$(zoxide init zsh)"

# fzf — fuzzy finder (Ctrl+R for history, Ctrl+T for files, Alt+C for dirs)
[ -s "/opt/homebrew/opt/fzf/shell/key-bindings.zsh" ] && source "/opt/homebrew/opt/fzf/shell/key-bindings.zsh"
[ -s "/opt/homebrew/opt/fzf/shell/completion.zsh" ] && source "/opt/homebrew/opt/fzf/shell/completion.zsh"
# Use fd as the default source for fzf (respects .gitignore, faster)
export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
export FZF_ALT_C_COMMAND='fd --type d --hidden --follow --exclude .git'

# Bun completions
[ -s "$BUN_INSTALL/_bun" ] && source "$BUN_INSTALL/_bun"

# ============================================================
# Aliases
# ============================================================
alias vegas='ssh costa@10.0.2.5'
alias pn='pnpm'

# eza (modern ls)
alias ls='eza --group-directories-first'
alias ll='eza -lh --group-directories-first --git'
alias la='eza -lah --group-directories-first --git'
alias lt='eza --tree --level=2 --group-directories-first'

# bat (modern cat with syntax highlighting)
alias cat='bat --paging=never'

# Git shortcuts (a handful of useful ones from OMZ)
alias g='git'
alias gs='git status'
alias gd='git diff'
alias gco='git checkout'
alias gcb='git checkout -b'
alias gp='git push'
alias gl='git pull'
alias glog='git log --oneline --graph --decorate'
ZSHRC_EOF

  if [[ -f "$zshrc" ]] && cmp -s "$tmp" "$zshrc"; then
    ok_line ".zshrc já está atualizado"
    rm -f "$tmp"
  else
    if [[ -f "$zshrc" ]]; then
      local backup="$zshrc.bak.$(date +%Y%m%d%H%M%S)"
      cp "$zshrc" "$backup"
      info "backup salvo em ${C_DIM}$backup${C_RESET}"
    fi
    mv "$tmp" "$zshrc"
    ok_line ".zshrc escrito"
  fi
}

# ============================================================
# Resumo final
# ============================================================
print_summary() {
  local total=$((COUNT_INSTALLED + COUNT_SKIPPED + COUNT_FAILED))
  header "Resumo"
  printf "  ${C_GREEN}%3d instalados${C_RESET}   ${C_DIM}%3d já existiam${C_RESET}   ${C_RED}%3d falhas${C_RESET}   ${C_BOLD}%3d total${C_RESET}\n" \
    "$COUNT_INSTALLED" "$COUNT_SKIPPED" "$COUNT_FAILED" "$total"

  if (( COUNT_FAILED > 0 )); then
    printf "\n${C_RED}Itens com falha:${C_RESET}\n"
    for item in "${FAILED_ITEMS[@]}"; do
      printf "  ${C_RED}✗${C_RESET} %s\n" "$item"
    done
  fi

  printf "\n${C_GREEN}${C_BOLD}Tudo pronto!${C_RESET} Abra um novo terminal ou rode ${C_CYAN}exec zsh${C_RESET}\n\n"
}

# ============================================================
# Main
# ============================================================
print_banner
ensure_not_root
preflight
ensure_sudo
install_homebrew
install_taps
install_formulas
install_casks
post_install
write_zshrc
print_summary
