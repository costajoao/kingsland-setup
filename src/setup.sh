#!/usr/bin/env bash
# kingsland-setup — idempotent macOS dev bootstrap
# Uso:
#   curl -fsSL https://kingsland.network/setup.sh | bash
#   # ou, para partes interativas (chsh/sudo):
#   curl -fsSL https://kingsland.network/setup.sh -o /tmp/setup.sh && bash /tmp/setup.sh
#
# Antes de instalar, um menu pergunta quais grupos instalar. Sem menu:
#   ... | bash -s -- --yes                  # padrões (tudo, menos mobile)
#   ... | bash -s -- --all                  # todos os grupos
#   ... | bash -s -- --groups=mobile,java   # só esses (o núcleo sempre entra)
#
# Must stay bash 3.2 compatible: `curl | bash` runs macOS's /bin/bash.

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
# stdin comes from /dev/null: under `curl | bash` stdin IS the rest of this
# script, and a child that reads it (an installer prompt) would swallow it.
run_quiet() {
  local logfile
  logfile="$(mktemp)"
  if "$@" </dev/null >"$logfile" 2>&1; then
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
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/null
    ok_line "Homebrew instalado"
  fi
  if [[ -x "$BREW_PREFIX/bin/brew" ]]; then
    eval "$("$BREW_PREFIX/bin/brew" shellenv)"
  fi
  # One update up front, then none per install (brew would otherwise refresh
  # its index before every `brew install`).
  sub "Atualizando índice do Homebrew"
  run_quiet brew update || warn "brew update falhou; seguindo com o índice atual"
  export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1
}

# ============================================================
# Grupos (menu de seleção)
# ============================================================
# One entry per group, in parallel arrays (bash 3.2 has no associative
# arrays). Package lists are space-separated. "core" is always installed.
GROUP_IDS=(core mobile java go bun python db docker media network ai dotfiles shell)
GROUP_LABELS=(
  "Núcleo (git, gh, fzf, ripgrep, starship, nvm …)"
  "Mobile / Android (Android Studio, SDK, apktool)"
  "Java (OpenJDK 21, Maven)"
  "Go (go, golang-migrate, overmind)"
  "Bun"
  "Python tooling (pipx, yamllint)"
  "Bancos de dados (psql/libpq, Redis Desktop Manager)"
  "Docker Compose (CLI)"
  "Mídia e imagens (ffmpeg, webp, librsvg, Inkscape …)"
  "Rede local (mkcert, ngrok)"
  "IA (Goose)"
  "Escrever ~/.zshrc (o atual vira backup)"
  "Definir zsh como shell padrão"
)
GROUP_DEFAULT=(1 0 1 1 1 1 1 1 1 1 1 1 1)
GROUP_TAPS=("" "" "" "" "oven-sh/bun" "" "" "" "" "" "" "" "")
GROUP_FORMULAS=(
  "bat coreutils eza fd fzf gcc gh git htop jq nvm pkgconf ripgrep sshs starship tree wget zoxide"
  "apktool"
  "openjdk@21 maven"
  "go golang-migrate overmind"
  "oven-sh/bun/bun"
  "pipx yamllint"
  "libpq"
  "docker-compose"
  "ffmpeg libpaper librsvg netpbm webp"
  "mkcert"
  ""
  ""
  ""
)
GROUP_CASKS=(
  ""
  "android-commandlinetools android-platform-tools android-studio"
  ""
  ""
  ""
  ""
  "another-redis-desktop-manager"
  ""
  "inkscape"
  "ngrok"
  "block-goose"
  ""
  ""
)
GROUP_SELECTED=("${GROUP_DEFAULT[@]}")

group_index() {
  local i
  for i in "${!GROUP_IDS[@]}"; do
    [[ "${GROUP_IDS[$i]}" == "$1" ]] && { echo "$i"; return 0; }
  done
  return 1
}
group_on() { local i; i="$(group_index "$1")" && [[ "${GROUP_SELECTED[$i]}" == 1 ]]; }

# --yes / --all / --groups=a,b (non-interactive). Unknown flags abort.
SELECTION_MODE="menu"
parse_args() {
  local arg i id
  for arg in "$@"; do
    case "$arg" in
      --yes|-y) SELECTION_MODE="defaults" ;;
      --all)
        SELECTION_MODE="flags"
        for i in "${!GROUP_IDS[@]}"; do GROUP_SELECTED[$i]=1; done ;;
      --groups=*)
        SELECTION_MODE="flags"
        for i in "${!GROUP_IDS[@]}"; do GROUP_SELECTED[$i]=0; done
        GROUP_SELECTED[0]=1
        local list="${arg#--groups=}"
        local IFS=,
        for id in $list; do
          if i="$(group_index "$id")"; then
            GROUP_SELECTED[$i]=1
          else
            err "grupo desconhecido: $id (válidos: ${GROUP_IDS[*]})"; exit 1
          fi
        done ;;
      -h|--help)
        printf "Uso: setup.sh [--yes | --all | --groups=%s]\n" "$(IFS=,; echo "${GROUP_IDS[*]}")"
        exit 0 ;;
      *) err "opção desconhecida: $arg"; exit 1 ;;
    esac
  done
}

# Checkbox menu. Reads from /dev/tty because stdin is the script under
# `curl | bash`. Numbers toggle (several per line), "a"/"n" select all/none,
# Enter installs. No terminal → defaults.
select_groups() {
  header "O que instalar"
  if [[ "$SELECTION_MODE" != "menu" ]]; then
    ok_line "seleção por opção de linha de comando"
  elif [[ ! -r /dev/tty ]] || ! { true </dev/tty; } 2>/dev/null; then
    warn "sem terminal para o menu; usando os padrões"
  else
    local i reply n
    while true; do
      for i in "${!GROUP_IDS[@]}"; do
        local box="[ ]" color="$C_DIM"
        if [[ "${GROUP_SELECTED[$i]}" == 1 ]]; then box="[x]"; color="$C_GREEN"; fi
        if (( i == 0 )); then
          printf "  ${C_DIM}  -${C_RESET} ${color}%s${C_RESET} %s ${C_DIM}(sempre)${C_RESET}\n" "$box" "${GROUP_LABELS[$i]}"
        else
          printf "  ${C_BOLD}%3d${C_RESET} ${color}%s${C_RESET} %s\n" "$i" "$box" "${GROUP_LABELS[$i]}"
        fi
      done
      printf "\n  Números para marcar/desmarcar (ex: ${C_CYAN}1 3${C_RESET}), ${C_CYAN}a${C_RESET} todos, ${C_CYAN}n${C_RESET} nenhum, ${C_CYAN}Enter${C_RESET} para instalar: "
      IFS= read -r reply </dev/tty || reply=""
      [[ -z "$reply" ]] && break
      case "$reply" in
        a|A) for i in "${!GROUP_IDS[@]}"; do GROUP_SELECTED[$i]=1; done ;;
        n|N) for i in "${!GROUP_IDS[@]}"; do GROUP_SELECTED[$i]=0; done; GROUP_SELECTED[0]=1 ;;
        *)
          for n in $reply; do
            if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n < ${#GROUP_IDS[@]} )); then
              GROUP_SELECTED[$n]=$(( 1 - GROUP_SELECTED[$n] ))
            else
              warn "ignorado: $n"
            fi
          done ;;
      esac
      printf "\n"
    done
  fi

  # Android needs a JDK: selecting mobile pulls Java in.
  if group_on mobile && ! group_on java; then
    GROUP_SELECTED[$(group_index java)]=1
    info "Java incluído automaticamente (necessário para Android)"
  fi

  local chosen=()
  for i in "${!GROUP_IDS[@]}"; do
    [[ "${GROUP_SELECTED[$i]}" == 1 ]] && chosen+=("${GROUP_IDS[$i]}")
  done
  ok_line "grupos: ${chosen[*]}"
}

# Flatten the selected groups into TAPS / FORMULAS / CASKS.
TAPS=() FORMULAS=() CASKS=()
collect_packages() {
  local i p
  for i in "${!GROUP_IDS[@]}"; do
    [[ "${GROUP_SELECTED[$i]}" == 1 ]] || continue
    for p in ${GROUP_TAPS[$i]}; do TAPS+=("$p"); done
    for p in ${GROUP_FORMULAS[$i]}; do FORMULAS+=("$p"); done
    for p in ${GROUP_CASKS[$i]}; do CASKS+=("$p"); done
  done
}

# ============================================================
# Instalação (taps, formulas, casks)
# ============================================================
# install_list <kind> <title> items... ; kind = tap | formula | cask.
# Failed items get one retry after the loop (downloads fail transiently).
install_list() {
  local kind=$1 title=$2; shift 2
  local items=("$@")
  (( ${#items[@]} )) || return 0
  header "$title (${#items[@]})"

  local present=""
  case "$kind" in
    tap)     present="$(brew tap 2>/dev/null || true)" ;;
    formula) present="$(brew list --formula -1 2>/dev/null || true)" ;;
    cask)    present="$(brew list --cask -1 2>/dev/null || true)" ;;
  esac

  local i=0 total=${#items[@]} item name failed=()
  for item in "${items[@]}"; do
    i=$((i+1))
    name="$item"; [[ "$kind" == tap ]] || name="${item##*/}"
    if printf "%s\n" "$present" | grep -qx "$name"; then
      render_item "$i" "$total" "$name" "already installed" "$C_DIM"
      COUNT_SKIPPED=$((COUNT_SKIPPED+1))
      continue
    fi
    render_item "$i" "$total" "$name" "installing…" "$C_YELLOW"
    if brew_install "$kind" "$item"; then
      tput cuu1 2>/dev/null && tput el 2>/dev/null || true
      render_item "$i" "$total" "$name" "installed" "$C_GREEN"
      COUNT_INSTALLED=$((COUNT_INSTALLED+1))
    else
      render_item "$i" "$total" "$name" "failed, retrying later" "$C_YELLOW"
      failed+=("$item")
    fi
  done

  for item in ${failed[@]+"${failed[@]}"}; do
    name="$item"; [[ "$kind" == tap ]] || name="${item##*/}"
    sub "Nova tentativa: $name"
    if brew_install "$kind" "$item"; then
      ok_line "$name instalado na segunda tentativa"
      COUNT_INSTALLED=$((COUNT_INSTALLED+1))
    else
      err "$name falhou duas vezes"
      COUNT_FAILED=$((COUNT_FAILED+1))
      FAILED_ITEMS+=("$kind:$item")
    fi
  done
}

brew_install() {
  case "$1" in
    tap)     run_quiet brew tap "$2" ;;
    formula) run_quiet brew install "$2" ;;
    cask)    run_quiet brew install --cask "$2" ;;
  esac
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
  if ! group_on shell; then
    info "shell padrão: não alterado (grupo desmarcado)"
  elif [[ -n "$zsh_bin" ]]; then
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
      # chsh asks for the password: read it from the terminal, not the pipe.
      if [[ -r /dev/tty ]] && chsh -s "$zsh_bin" </dev/tty; then
        ok_line "shell padrão atualizado"
      else
        warn "rode manualmente: chsh -s $zsh_bin"
      fi
    fi
  fi
}

# ============================================================
# .zshrc
# ============================================================
write_zshrc() {
  header "Dotfiles"
  if ! group_on dotfiles; then
    info "~/.zshrc: não alterado (grupo desmarcado)"
    return 0
  fi
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
setopt SHARE_HISTORY            # share history across sessions (also appends immediately)
setopt EXTENDED_HISTORY         # save timestamps

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
# Docker CLI completions live here too, so compinit runs once and keeps its
# cache. If Docker Desktop appends its own "compinit" block to this file,
# delete it: an uncached compinit on every shell costs ~400 ms.
fpath=(/opt/homebrew/share/zsh/site-functions $HOME/.docker/completions $fpath)

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
# NVM (lazy: default Node on PATH, nvm.sh loaded on first `nvm`)
# ============================================================
# The default Node goes straight onto PATH, resolved from nvm's own "default"
# alias (so `nvm alias default X` still takes effect), and nvm.sh (~300 ms)
# loads only the first time `nvm` is called. Unlike node/npm shim functions,
# this keeps `#!/usr/bin/env node` scripts and child processes working.
export NVM_DIR="$HOME/.nvm"
() {
  local alias_file="$NVM_DIR/alias/default" want=""
  [[ -r $alias_file ]] && want=$(<$alias_file)
  want=${want#v}
  local -a dirs
  dirs=($NVM_DIR/versions/node/v${want}*(N/nOn))             # newest match first
  (( ${#dirs} )) || dirs=($NVM_DIR/versions/node/v*(N/nOn))  # alias like lts/*: newest installed
  (( ${#dirs} )) && path=($dirs[1]/bin $path)
}
nvm() {
  unfunction nvm
  [ -s "/opt/homebrew/opt/nvm/nvm.sh" ] && \. "/opt/homebrew/opt/nvm/nvm.sh"
  nvm "$@"
}

# ============================================================
# Modern tools
# ============================================================
# Starship prompt: its init script is cached and rebuilt only when the
# starship binary is newer than the cache (i.e. after an upgrade).
() {
  local cache="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/starship-init.zsh"
  local bin="${commands[starship]}"
  [[ -n $bin ]] || return
  if [[ ! -s $cache || $bin -nt $cache ]]; then
    mkdir -p "${cache:h}" && starship init zsh --print-full-init >| "$cache"
  fi
  source "$cache"
}

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
alias costa-agent='ssh costa@10.30.15.222'
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

# ============================================================
# GitHub Packages
# ============================================================
# pnpm/npm read NODE_AUTH_TOKEN via .npmrc. Exported in every shell from a
# read:packages-only PAT in the macOS keychain, stored once with
#   security add-generic-password -U -a "$USER" -s NODE_AUTH_TOKEN -w
# Deliberately no fallback to `gh auth token`: that token carries the user's
# full scopes (repo, admin…) and would reach every process. No keychain entry,
# no variable. The token is never stored in this file.
NODE_AUTH_TOKEN=$(security find-generic-password -a "$USER" -s NODE_AUTH_TOKEN -w 2>/dev/null)
if [[ -n $NODE_AUTH_TOKEN ]]; then export NODE_AUTH_TOKEN; else unset NODE_AUTH_TOKEN; fi
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
# Everything runs from main(), called on the last line: under `curl | bash`
# bash reads the script from the pipe as it goes, so top-level calls not yet
# read could be swallowed by any child that reads stdin, and the run would
# stop silently halfway (it took three runs to finish on one machine).
main() {
  parse_args "$@"
  print_banner
  ensure_not_root
  preflight
  select_groups
  collect_packages
  ensure_sudo
  install_homebrew
  install_list tap "Taps" ${TAPS[@]+"${TAPS[@]}"}
  install_list formula "Formulas" ${FORMULAS[@]+"${FORMULAS[@]}"}
  install_list cask "Casks" ${CASKS[@]+"${CASKS[@]}"}
  post_install
  write_zshrc
  print_summary
}

main "$@"
