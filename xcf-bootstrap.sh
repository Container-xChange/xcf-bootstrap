#!/usr/bin/env bash
#
# xcf-bootstrap.sh — bootstrap GitHub CLI + clone xC repos into an ~/xcf workspace.
#
# Detects the OS, ensures every dependency it needs (git, jq, fzf, gh) is
# installed, authenticates with GitHub, lists org repositories filtered by the
# `business_unit` custom property, lets you multiselect which to clone, then
# clones the baseline repos plus your selection into an `xcf` directory.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config — EDIT THESE before first run.
# ---------------------------------------------------------------------------
ORG="Container-xChange"
BUSINESS_UNIT="xCF"
BASELINE_REPOS=( "engineering" "knowledge" )
INSTALL_REPO="engineering"   # baseline repo hosting scripts/install-xc.sh (run as the closing step)
DEFAULT_XCF_DIR="$HOME/xcf"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

info()  { printf '%s==>%s %s\n' "$C_BLUE"   "$C_RESET" "$*"; }
ok()    { printf '%s ✓%s %s\n'  "$C_GREEN"  "$C_RESET" "$*"; }
warn()  { printf '%s ! %s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()   { printf '%s ✗ %s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# OS / distro detection
# ---------------------------------------------------------------------------
OS=""        # macos | linux
PKG_MGR=""   # brew | apt | pacman | dnf

detect_platform() {
  local uname_s
  uname_s="$(uname -s)"
  case "$uname_s" in
    Darwin)
      OS="macos"
      PKG_MGR="brew"
      ;;
    Linux)
      OS="linux"
      [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release; unsupported Linux distro. See https://cli.github.com"
      # shellcheck disable=SC1091
      . /etc/os-release
      local ids="${ID:-} ${ID_LIKE:-}"
      case " $ids " in
        *" debian "*|*" ubuntu "*) PKG_MGR="apt" ;;
        *" arch "*)                PKG_MGR="pacman" ;;
        *" fedora "*|*" rhel "*|*" centos "*) PKG_MGR="dnf" ;;
        *) die "Unsupported Linux distro (ID='${ID:-?}'). Install deps manually; see https://cli.github.com" ;;
      esac
      ;;
    *)
      die "Unsupported OS '$uname_s'. See https://cli.github.com"
      ;;
  esac
  ok "Detected $OS (package manager: $PKG_MGR)"
}

# ---------------------------------------------------------------------------
# Dependency installation
#
# No tool is assumed present — every dependency runs through ensure_tool /
# ensure_gh, which check first and install only if missing.
# ---------------------------------------------------------------------------
command_exists() { command -v "$1" >/dev/null 2>&1; }

# Run a privileged command, using sudo only when not already root.
maybe_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command_exists sudo; then
    sudo "$@"
  else
    die "Need root to run: $* (install sudo or run this script as root)"
  fi
}

# ensure_tool <command> <brew-pkg> <apt-pkg> <pacman-pkg> <dnf-pkg>
ensure_tool() {
  local cmd="$1" brew_pkg="$2" apt_pkg="$3" pacman_pkg="$4" dnf_pkg="$5"
  if command_exists "$cmd"; then
    ok "$cmd already installed"
    return 0
  fi
  info "Installing $cmd ..."
  case "$PKG_MGR" in
    brew)   brew install "$brew_pkg" ;;
    apt)    maybe_sudo apt-get update && maybe_sudo apt-get install -y "$apt_pkg" ;;
    pacman) maybe_sudo pacman -S --needed --noconfirm "$pacman_pkg" ;;
    dnf)    maybe_sudo dnf install -y "$dnf_pkg" ;;
  esac
  command_exists "$cmd" || die "Failed to install $cmd"
  ok "$cmd installed"
}

# gh gets its own function: on Linux it needs the official cli.github.com repo
# set up before the package is available.
ensure_gh() {
  if command_exists gh; then
    ok "gh already installed"
    return 0
  fi
  info "Installing GitHub CLI (gh) ..."
  case "$PKG_MGR" in
    brew)
      brew install gh
      ;;
    apt)
      # Official instructions: https://cli.github.com (via cli.github.com apt repo)
      maybe_sudo mkdir -p -m 755 /etc/apt/keyrings
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | maybe_sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
      maybe_sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | maybe_sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
      maybe_sudo apt-get update
      maybe_sudo apt-get install -y gh
      ;;
    pacman)
      # Arch ships gh as the official 'github-cli' package — NOT via AUR.
      maybe_sudo pacman -S --needed --noconfirm github-cli
      ;;
    dnf)
      maybe_sudo dnf install -y 'dnf-command(config-manager)'
      maybe_sudo dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
      maybe_sudo dnf install -y gh
      ;;
  esac
  command_exists gh || die "Failed to install gh"
  ok "gh installed"
}

ensure_dependencies() {
  # On macOS, everything flows through Homebrew — require it explicitly.
  if [[ "$PKG_MGR" == "brew" ]] && ! command_exists brew; then
    die "Homebrew is required on macOS. Install it from https://brew.sh and re-run."
  fi
  # curl is needed to add the gh apt repo on Debian/Ubuntu.
  if [[ "$PKG_MGR" == "apt" ]]; then
    ensure_tool curl curl curl curl curl
  fi
  ensure_tool git git git git git
  ensure_tool jq  jq  jq  jq  jq
  ensure_tool fzf fzf fzf fzf fzf
  ensure_gh
}

# ---------------------------------------------------------------------------
# GitHub authentication
# ---------------------------------------------------------------------------
ensure_authenticated() {
  if gh auth status >/dev/null 2>&1; then
    ok "GitHub authenticated"
    return 0
  fi
  warn "Not authenticated with GitHub — launching 'gh auth login'."
  gh auth login
  gh auth status >/dev/null 2>&1 || die "GitHub authentication failed."
  ok "GitHub authenticated"
}

# ---------------------------------------------------------------------------
# Fetch repos filtered by the business_unit custom property
# ---------------------------------------------------------------------------
fetch_repos() {
  local repos
  # Primary: server-side filter via the props.<name>:<value> search qualifier.
  # jq -r is applied locally so a non-JSON/error body doesn't abort the run.
  repos="$(gh api --paginate \
      "/orgs/$ORG/properties/values?repository_query=props.business_unit:$(jq -rn --arg v "$BUSINESS_UNIT" '$v|@uri')" \
      2>/dev/null | jq -r '.[]?.repository_name' 2>/dev/null | sort -u || true)"

  # Fallback: list all values and filter client-side.
  if [[ -z "$repos" ]]; then
    warn "Server-side filter returned nothing — falling back to client-side filtering."
    repos="$(BU="$BUSINESS_UNIT" gh api --paginate "/orgs/$ORG/properties/values" 2>/dev/null \
      | jq -r '.[] | select(any(.properties[]?; .property_name=="business_unit" and .value==env.BU)) | .repository_name' 2>/dev/null \
      | sort -u || true)"
  fi

  [[ -n "$repos" ]] || die "No repositories found in '$ORG' with business_unit='$BUSINESS_UNIT'."
  printf '%s\n' "$repos"
}

# Read a repo list on stdin and emit only those NOT already cloned in $XCF_DIR.
# Keeps stdout to survivors only; the skipped count is reported by the caller.
exclude_present() {
  local repo
  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    [[ -d "$XCF_DIR/$repo" ]] && continue
    printf '%s\n' "$repo"
  done
}

# ---------------------------------------------------------------------------
# Multiselect via fzf
# ---------------------------------------------------------------------------
SELECTED_REPOS=()
select_repos() {
  local repo_list="$1" selection
  # fzf returns non-zero on cancel (Esc/Ctrl-C); tolerate it.
  selection="$(printf '%s\n' "$repo_list" \
    | fzf --multi \
          --prompt='select repos> ' \
          --header=$'TAB/Shift-TAB to mark, ENTER to confirm, ESC for baseline only' \
          --border 2>/dev/null || true)"

  if [[ -z "$selection" ]]; then
    SELECTED_REPOS=()
    return 0
  fi
  while IFS= read -r line; do
    [[ -n "$line" ]] && SELECTED_REPOS+=("$line")
  done <<< "$selection"
}

# ---------------------------------------------------------------------------
# Resolve the xcf working directory
# ---------------------------------------------------------------------------
# Recover a previously-persisted XCF_MONO_ROOT straight from the shell rc files.
# Covers the case where a prior run wrote the value but the shell running this
# script has not sourced it yet, so it is absent from the live environment.
# Echoes the recovered path (empty if none found).
recover_persisted_root() {
  local sh rc path
  for sh in zsh bash fish; do
    rc="$(_shell_rc "$sh")" || continue
    [[ -f "$rc" ]] || continue
    # Extract the single-quoted value from the last XCF_MONO_ROOT line. Both the
    # bash/zsh (`export …=`) and fish (`set -gx …`) forms single-quote the path,
    # so splitting on the quote and taking the 2nd field yields it.
    path="$(awk -F\' '/XCF_MONO_ROOT/ {v=$2} END{if (v!="") print v}' "$rc" 2>/dev/null)"
    if [[ -n "$path" ]]; then
      printf '%s\n' "$path"
      return 0
    fi
  done
}

# Heuristic: does <dir> look like an xcf workspace root? True when it is named
# 'xcf' or already contains a baseline checkout. Used only to pick a sensible
# default when nothing has been recorded yet — lets you run the script from
# inside the workspace you actually mean.
looks_like_xcf_root() {
  local dir="$1" r
  [[ -d "$dir" ]] || return 1
  [[ "$(basename "$dir")" == "xcf" ]] && return 0
  for r in ${BASELINE_REPOS[@]+"${BASELINE_REPOS[@]}"}; do
    [[ -n "$r" && -d "$dir/$r" ]] && return 0
  done
  return 1
}

XCF_DIR=""
resolve_xcf_dir() {
  # Precedence for the DEFAULT we offer (highest first):
  #   1. XCF_MONO_ROOT — live in this shell, else recovered from the shell rc
  #      files (the "written on a prior run but not sourced yet" case). This
  #      always wins when present.
  #   2. The current directory, but only when nothing is recorded AND it looks
  #      like an xcf workspace — so running from inside the workspace works.
  #   3. The built-in default, $HOME/xcf.
  # Whatever we land on is only a DEFAULT: the user is ALWAYS prompted and may
  # type any other path to override it. The final choice is persisted back to
  # XCF_MONO_ROOT by persist_mono_root() (called right after this in main).
  local candidate="" origin=""
  if [[ -n "${XCF_MONO_ROOT:-}" ]]; then
    candidate="$XCF_MONO_ROOT"; origin="XCF_MONO_ROOT (environment)"
  else
    candidate="$(recover_persisted_root)"
    [[ -n "$candidate" ]] && origin="XCF_MONO_ROOT (shell config — not yet sourced)"
  fi
  if [[ -z "$candidate" ]] && looks_like_xcf_root "$PWD"; then
    candidate="$PWD"; origin="current directory"
  fi
  if [[ -z "$candidate" ]]; then
    candidate="$DEFAULT_XCF_DIR"; origin="default"
  fi
  # Expand a leading ~ (a recorded value could contain one) before showing it.
  candidate="${candidate/#\~/$HOME}"
  info "Suggested xcf workspace: $candidate  [$origin]"

  local ans note=""
  [[ -d "$candidate" ]] || note=" — will be created"
  read -r -p "Install the xcf workspace here? ENTER to accept [$candidate]$note, or type a different path: " ans

  local chosen="${ans:-$candidate}"
  chosen="${chosen/#\~/$HOME}"       # expand a leading ~ in a typed path too
  [[ -n "$chosen" ]] || die "No path provided."
  mkdir -p "$chosen"
  XCF_DIR="$(cd "$chosen" && pwd)"   # resolve to an absolute path
  ok "Using xcf directory: $XCF_DIR"
}

# ---------------------------------------------------------------------------
# Persist XCF_MONO_ROOT (the xcf workspace root) for install-xc.sh + daily use
# ---------------------------------------------------------------------------
_MR_BEGIN="# >>> xcf-bootstrap (XCF_MONO_ROOT) >>>"
_MR_END="# <<< xcf-bootstrap (XCF_MONO_ROOT) <<<"

# Replace (or append) our managed block in <file> with <line>, idempotently.
_write_managed_block() {
  local file="$1" line="$2" dir tmp perm
  dir="$(dirname "$file")"
  mkdir -p "$dir"
  [[ -e "$file" ]] || : > "$file"
  # Build the new content in a temp alongside the target (same filesystem) so the
  # final swap is atomic and never leaves a half-written rc file.
  tmp="$(mktemp "$dir/.xcf-rc.XXXXXX")"
  if ! awk -v b="$_MR_BEGIN" -v e="$_MR_END" '
    $0==b {skip=1; next}
    skip && $0==e {skip=0; next}
    !skip {print}
  ' "$file" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  {
    printf '%s\n' "$_MR_BEGIN"
    printf '%s\n' "$line"
    printf '%s\n' "$_MR_END"
  } >> "$tmp"

  if [[ -L "$file" ]]; then
    # Symlinked rc (dotfile managers like chezmoi/stow): write through the link to
    # keep it intact. Trade-off: this path is not atomic.
    cat "$tmp" > "$file"
    rm -f "$tmp"
  else
    # Regular file: preserve perms, then atomically rename (no truncation window).
    perm="$(stat -f '%Lp' "$file" 2>/dev/null || stat -c '%a' "$file" 2>/dev/null || echo 644)"
    chmod "$perm" "$tmp" 2>/dev/null || true
    mv "$tmp" "$file"
  fi
}

# Conventional rc file for a shell name (bash honours the OS convention).
_shell_rc() {
  case "$1" in
    zsh)  printf '%s\n' "$HOME/.zshrc" ;;
    bash) [[ "$OS" == "macos" ]] && printf '%s\n' "$HOME/.bash_profile" || printf '%s\n' "$HOME/.bashrc" ;;
    fish) printf '%s\n' "$HOME/.config/fish/config.fish" ;;
    *)    return 1 ;;
  esac
}

# Export statement in the right syntax for a shell (fish differs). Single-quoted
# so the path isn't re-expanded ($/backtick/quote) when the rc is next sourced.
_shell_export_line() {
  if [[ "$1" == "fish" ]]; then
    printf "set -gx XCF_MONO_ROOT '%s'" "$2"
  else
    printf "export XCF_MONO_ROOT='%s'" "$2"
  fi
}

# Set XCF_MONO_ROOT for this process and persist it to the active shell's rc
# (always) plus any other shell whose rc already exists.
persist_mono_root() {
  local root="$XCF_DIR"
  export XCF_MONO_ROOT="$root"   # current process — install-xc.sh inherits it

  local active rc sh
  local -a updated=()
  active="$(basename "${SHELL:-}")"
  for sh in zsh bash fish; do
    rc="$(_shell_rc "$sh")" || continue
    if [[ "$sh" == "$active" || -f "$rc" ]]; then
      _write_managed_block "$rc" "$(_shell_export_line "$sh" "$root")"
      updated+=("$rc")
    fi
  done

  ok "XCF_MONO_ROOT=$root"
  if [[ "${#updated[@]}" -gt 0 ]]; then
    info "Persisted to: ${updated[*]}"
    info "Open a new shell (or 'source' the file) to pick it up in existing sessions."
  else
    warn "No shell rc found to update — set it manually: export XCF_MONO_ROOT=\"$root\""
  fi
}

# ---------------------------------------------------------------------------
# Clone
# ---------------------------------------------------------------------------
clone_repos() {
  local -a to_clone=()
  local seen=" "
  local repo
  # Baseline first, then selection — de-duplicated.
  for repo in ${BASELINE_REPOS[@]+"${BASELINE_REPOS[@]}"} ${SELECTED_REPOS[@]+"${SELECTED_REPOS[@]}"}; do
    [[ -n "$repo" ]] || continue
    if [[ "$seen" != *" $repo "* ]]; then
      to_clone+=("$repo")
      seen+="$repo "
    fi
  done

  [[ "${#to_clone[@]}" -gt 0 ]] || die "Nothing to clone (no baseline repos configured and no selection)."

  local cloned=0 skipped=0 failed=0
  for repo in "${to_clone[@]}"; do
    local dest="$XCF_DIR/$repo"
    if [[ -d "$dest/.git" ]]; then
      warn "Skipping $repo — already present at $dest"
      ((skipped++)) || true
      continue
    elif [[ -e "$dest" ]]; then
      # Present-check is /.git-consistent with update_one_repo: a leftover
      # non-git dir (e.g. a half-failed clone) is surfaced, not silently kept.
      warn "$repo: $dest exists but is not a git checkout — remove it and re-run to clone. Skipping."
      ((failed++)) || true
      continue
    fi
    info "Cloning $ORG/$repo ..."
    if gh repo clone "$ORG/$repo" "$dest"; then
      ok "Cloned $repo"
      ((cloned++)) || true
    else
      warn "Failed to clone $repo"
      ((failed++)) || true
    fi
  done

  printf '\n%sSummary:%s cloned=%d skipped=%d failed=%d → %s\n' \
    "$C_BOLD" "$C_RESET" "$cloned" "$skipped" "$failed" "$XCF_DIR"
  # Best-effort: surface failures but don't abort the rest of setup (update /
  # install-xc / unstash). run_install_xc guards its own missing-file case.
  [[ "$failed" -eq 0 ]] || warn "$failed repo(s) failed — continuing with the rest of setup."
}

# ---------------------------------------------------------------------------
# Update baseline repos to latest main (auto-stash local work)
# ---------------------------------------------------------------------------
STASHED_REPOS=()   # baseline repos whose local changes we auto-stashed

# Echo the remote default branch for a repo (strip 'origin/'); fall back to main.
default_branch() {
  local dir="$1" ref
  ref="$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)" || true
  if [[ -n "$ref" ]]; then
    printf '%s\n' "${ref#origin/}"
  else
    printf 'main\n'
  fi
}

# Fast-forward the current branch to its remote; non-fatal on divergence.
_ff_update() {
  local repo="$1" dir="$2" branch="$3"
  if git -C "$dir" pull --ff-only --quiet origin "$branch"; then
    ok "$repo updated to latest $branch"
  else
    warn "$repo: could not fast-forward '$branch' (diverged?) — left as-is."
  fi
}

# Stash dirty tracked changes (recording the origin branch for later restore),
# switch to the default branch if needed, then fast-forward.
_switch_to_latest() {
  local repo="$1" dir="$2" branch="$3" current="$4" dirty="$5"
  if [[ "$dirty" -eq 1 ]]; then
    warn "$repo: stashing uncommitted changes."
    if git -C "$dir" stash push -m "xcf-bootstrap auto-stash" >/dev/null; then
      STASHED_REPOS+=("$repo|$current")   # remember the branch the stash came from
    else
      warn "$repo: stash failed — skipping update to avoid clobbering local work."
      return 0
    fi
  fi
  if [[ "$current" != "$branch" ]]; then
    if ! git -C "$dir" checkout --quiet "$branch"; then
      warn "$repo: could not switch to '$branch' — skipping update."
      return 0
    fi
  fi
  _ff_update "$repo" "$dir" "$branch"
}

# Bring a baseline repo up to date. The INSTALL_REPO is special: we execute
# install-xc.sh from it, so it defaults to the latest default branch, but an
# active developer is offered the choice to run their own version instead.
# All git failures are non-fatal so one bad repo can't abort the run.
update_one_repo() {
  local repo="$1"
  local dir="$XCF_DIR/$repo"
  local branch current dirty=0
  if [[ ! -d "$dir/.git" ]]; then
    warn "$repo is not a git checkout at $dir — skipping update."
    return 0
  fi
  info "Updating $repo to latest ..."
  if ! git -C "$dir" fetch --quiet origin; then
    warn "$repo: fetch failed — skipping update."
    return 0
  fi
  # Refresh origin/HEAD so default_branch resolves the repo's real default
  # (master or main) rather than silently falling back to 'main'. Non-fatal.
  git -C "$dir" remote set-head origin --auto >/dev/null 2>&1 || true
  branch="$(default_branch "$dir")"
  current="$(git -C "$dir" symbolic-ref --short -q HEAD || true)"
  if ! git -C "$dir" diff --quiet || ! git -C "$dir" diff --cached --quiet; then
    dirty=1
  fi

  if [[ "$repo" == "$INSTALL_REPO" ]]; then
    # Clean and already on the default branch → just fast-forward.
    if [[ "$current" == "$branch" && "$dirty" -eq 0 ]]; then
      _ff_update "$repo" "$dir" "$branch"
      return 0
    fi
    # Otherwise the user is working on the installer repo — let them choose.
    local ans desc
    if [[ "$current" != "$branch" ]]; then
      desc="on branch '${current:-detached HEAD}'"
    else
      desc="with uncommitted changes on '$branch'"
    fi
    warn "$repo: you are $desc — this is the repo install-xc.sh runs from."
    read -r -p "Run install-xc.sh with (k)eep your version, or (l)atest $branch [stash + update]? [k/L] " ans
    if [[ "${ans:-L}" =~ ^[Kk]([Ee][Ee][Pp])?$ ]]; then
      info "$repo: keeping your version — install-xc.sh will run $desc."
      return 0
    fi
    _switch_to_latest "$repo" "$dir" "$branch" "$current" "$dirty"
  else
    # Other baselines: only update when already on the default branch; never
    # disturb a feature branch.
    if [[ "$current" != "$branch" ]]; then
      warn "$repo: on '${current:-detached HEAD}', not '$branch' — leaving as-is."
      return 0
    fi
    _switch_to_latest "$repo" "$dir" "$branch" "$current" "$dirty"
  fi
}

update_baseline_repos() {
  local repo
  for repo in ${BASELINE_REPOS[@]+"${BASELINE_REPOS[@]}"}; do
    [[ -n "$repo" ]] || continue
    update_one_repo "$repo"
  done
}

# Ask whether to restore each auto-stashed repo. Entries are "repo|origbranch";
# the stash is popped back onto the branch it came from. Runs from the EXIT trap
# so it executes even if a later step aborts.
offer_unstash() {
  [[ "${#STASHED_REPOS[@]}" -gt 0 ]] || return 0
  local entry repo origbranch dir ans cur
  printf '\n'
  info "These repos had local changes auto-stashed before updating:"
  for entry in "${STASHED_REPOS[@]}"; do printf '    - %s\n' "${entry%%|*}"; done
  for entry in "${STASHED_REPOS[@]}"; do
    repo="${entry%%|*}"; origbranch="${entry#*|}"
    dir="$XCF_DIR/$repo"
    read -r -p "Restore stashed changes in $repo (onto '${origbranch:-original state}')? [y/N] " ans
    if [[ "${ans:-N}" =~ ^[Yy]([Ee][Ss])?$ ]]; then
      # Return to the branch the stash came from before popping, if needed.
      cur="$(git -C "$dir" symbolic-ref --short -q HEAD || true)"
      if [[ -n "$origbranch" && "$cur" != "$origbranch" ]]; then
        git -C "$dir" checkout --quiet "$origbranch" \
          || warn "$repo: could not switch back to '$origbranch' — popping onto '$cur'."
      fi
      if git -C "$dir" stash pop; then
        ok "$repo: stash restored."
      else
        warn "$repo: stash pop hit conflicts — resolve manually (git -C \"$dir\" status)."
      fi
    else
      info "$repo: left stashed. Restore later with: git -C \"$dir\" stash pop"
    fi
  done
}

# EXIT-time cleanup: offer to restore stashed work even if a later step (e.g.
# install-xc.sh) aborts under set -e. Preserves the original exit status.
_cleanup() {
  local rc=$?
  offer_unstash || true
  exit "$rc"
}

# ---------------------------------------------------------------------------
# Closing action: ensure engineering/scripts/install-xc.sh is executable, run once
# ---------------------------------------------------------------------------
run_install_xc() {
  local script="$XCF_DIR/$INSTALL_REPO/scripts/install-xc.sh"
  if [[ ! -f "$script" ]]; then
    warn "Expected install script not found at $script — skipping closing step."
    return 0
  fi
  # Default-yes confirmation — the installer normally runs, but give the user a way out.
  local ans
  read -r -p "Run install-xc.sh now? [Y/n] " ans
  if [[ -n "${ans:-}" && ! "${ans}" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    info "Skipping install-xc.sh — run it later with: ( cd \"$(dirname "$script")\" && ./install-xc.sh )"
    return 0
  fi
  # chmod is a prerequisite for running via ./, not an alternative to running.
  if [[ ! -x "$script" ]]; then
    info "Setting executable bit on install-xc.sh"
    chmod +x "$script"
  fi
  info "Running install-xc.sh ..."
  ( cd "$(dirname "$script")" && ./install-xc.sh )
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
validate_config() {
  [[ -n "$ORG" ]]           || die "ORG is not set — edit the config block at the top of this script."
  [[ -n "$BUSINESS_UNIT" ]] || die "BUSINESS_UNIT is not set — edit the config block at the top of this script."
  local r have_baseline=0
  for r in "${BASELINE_REPOS[@]}"; do [[ -n "$r" ]] && have_baseline=1; done
  [[ "$have_baseline" -eq 1 ]] || warn "BASELINE_REPOS is empty — only your selection will be cloned."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  # This script is interactive (gh auth login, read prompts, fzf). Piping it
  # (curl … | bash) makes stdin the script body, so prompts read garbage and fzf
  # has no TTY. Require a real terminal; document `bash <(curl …)` instead.
  [[ -t 0 ]] || die "Run this from a terminal — e.g.  bash <(curl -fsSL <url>)  — not via 'curl … | bash'."

  validate_config
  detect_platform
  ensure_dependencies
  ensure_authenticated

  # Resolve the workspace first so we can exclude repos already cloned there.
  resolve_xcf_dir

  # Publish the workspace root so install-xc.sh and the engineering harness see it.
  persist_mono_root

  info "Fetching repositories in '$ORG' with business_unit='$BUSINESS_UNIT' ..."
  local repo_list filtered_list found_count present_count
  repo_list="$(fetch_repos)"
  found_count="$(printf '%s\n' "$repo_list" | grep -c . )"

  # Drop repos already present in $XCF_DIR so they don't clutter the picker.
  filtered_list="$(printf '%s\n' "$repo_list" | exclude_present)"
  present_count=$(( found_count - $(printf '%s\n' "$filtered_list" | grep -c . ) ))
  ok "Found $found_count matching repositories ($present_count already present in $XCF_DIR)."

  if [[ -z "$filtered_list" ]]; then
    info "All matching xCF repos are already present in $XCF_DIR — nothing new to select."
    SELECTED_REPOS=()
  else
    select_repos "$filtered_list"
    if [[ "${#SELECTED_REPOS[@]}" -gt 0 ]]; then
      ok "Selected: ${SELECTED_REPOS[*]}"
    else
      warn "No repositories selected — cloning baseline repos only."
    fi
  fi

  clone_repos
  # From here a repo may be auto-stashed; ensure the restore prompt runs even if
  # a later step (e.g. install-xc.sh) aborts under set -e.
  trap _cleanup EXIT
  update_baseline_repos
  run_install_xc
}

main "$@"
