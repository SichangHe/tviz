#!/usr/bin/env bash
# tviz installer.  curl -fsSL https://raw.githubusercontent.com/SichangHe/tviz/main/install.sh | bash -s -- [OPTIONS]
#   --iterm2         macOS: viz pane in iTerm2's sidebar (default on macOS; needs iTerm2 3.6+)
#   --client         macOS: install the standalone tviz.app instead
#   --server         install `viz` + viz server (default on Linux)
#   --host HOST      client: also print/run the ssh forward to HOST
#   --autossh        client with --host: start a persistent autossh forward now
#   --app-dir DIR    client: where tviz.app goes (default /Applications, else ~/Applications)
#   --bin-dir DIR    server: where `viz` goes (default ~/.local/bin)
#   --no-service     server: do not install/start the background service
#   --ref REF        git ref to install the server from (default main)
#   --uninstall      remove what this script installed for the chosen role
set -euo pipefail
usage() { cat <<'U'
tviz installer: bash install.sh [--iterm2|--client|--server] [OPTIONS]
  --iterm2         macOS: viz pane in iTerm2's sidebar (default on macOS; needs iTerm2 3.6+)
  --client         macOS: install the standalone tviz.app instead
  --server         install `viz` + viz server (default on Linux)
  --host HOST      client: name the server for the ssh forward
  --autossh        client with --host: start a persistent autossh forward now
  --app-dir DIR    client: where tviz.app goes (default /Applications, else ~/Applications)
  --bin-dir DIR    server: where `viz` goes (default ~/.local/bin)
  --no-service     server: do not install/start the systemd user service
  --ref REF        server: git ref to install from (default main)
  --uninstall      remove what this script installed for the chosen role
U
}
REPO=SichangHe/tviz REF=main ROLE= HOST= AUTOSSH=0 SERVICE=1 UNINSTALL=0
APP_DIR= BIN_DIR="$HOME/.local/bin" SHARE="$HOME/.local/share/tviz"
while (($#)); do case "$1" in
  --client) ROLE=client;; --iterm2) ROLE=iterm2;; --server) ROLE=server;;
  --host) HOST="$2"; shift;; --autossh) AUTOSSH=1;;
  --app-dir) APP_DIR="$2"; shift;; --bin-dir) BIN_DIR="$2"; shift;;
  --no-service) SERVICE=0;; --ref) REF="$2"; shift;; --uninstall) UNINSTALL=1;;
  -h|--help) usage; exit 0;;
  *) echo "unknown option: $1" >&2; exit 2;;
esac; shift; done
[[ -n $ROLE ]] || { [[ $(uname) == Darwin ]] && ROLE=iterm2 || ROLE=server; }
say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
forward="ssh -N -L 8790:127.0.0.1:8790 ${HOST:-HOST}"

keep_forward() {
  if ((AUTOSSH)) && [[ -n $HOST ]]; then
    command -v autossh >/dev/null || { echo "autossh missing: brew install autossh" >&2; exit 1; }
    autossh -M 0 -f -N -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -L 8790:127.0.0.1:8790 "$HOST"
    say "autossh forward to $HOST started"
  else
    echo "viz needs a forward to the server, e.g.: $forward"
    echo "  or add  LocalForward 8790 127.0.0.1:8790  to that host in ~/.ssh/config"
    echo "  or rerun with --host HOST --autossh to keep one alive"
  fi
}

iterm2() {
  [[ $(uname) == Darwin ]] || { echo "iTerm2 is macOS only" >&2; exit 1; }
  dir="$HOME/Library/Application Support/iTerm2/Scripts/AutoLaunch"
  if ((UNINSTALL)); then rm -f "$dir/tviz.py"; say "removed $dir/tviz.py"; return; fi
  [[ -d /Applications/iTerm.app ]] || echo "iTerm2 not found: brew install --cask iterm2 (3.6+)"
  mkdir -p "$dir"
  curl -fsSL -o "$dir/tviz.py" "https://raw.githubusercontent.com/$REPO/$REF/iterm2/tviz.py"
  defaults write com.googlecode.iterm2 EnableAPIServer -bool true
  say "installed $dir/tviz.py"
  echo "restart iTerm2; if asked, allow the Python runtime download and the tviz script's API access"
  keep_forward
}

client() {
  [[ $(uname) == Darwin ]] || { echo "tviz.app is macOS only" >&2; exit 1; }
  [[ -n $APP_DIR ]] || { [[ -w /Applications ]] && APP_DIR=/Applications || APP_DIR="$HOME/Applications"; }
  if ((UNINSTALL)); then rm -rf "$APP_DIR/tviz.app"; say "removed $APP_DIR/tviz.app"; return; fi
  mkdir -p "$APP_DIR"; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  say "downloading tviz.app"
  curl -fsSL -o "$tmp/t.zip" "https://github.com/$REPO/releases/download/nightly/tviz-macos.zip"
  ditto -x -k "$tmp/t.zip" "$tmp"
  rm -rf "$APP_DIR/tviz.app"; mv "$tmp/tviz.app" "$APP_DIR/"
  xattr -dr com.apple.quarantine "$APP_DIR/tviz.app" 2>/dev/null || true  # unsigned build
  say "installed $APP_DIR/tviz.app"
  keep_forward
  open "$APP_DIR/tviz.app"
}

server() {
  unit="$HOME/.config/systemd/user/tviz.service"
  if ((UNINSTALL)); then
    systemctl --user disable --now tviz.service 2>/dev/null || true
    rm -rf "$SHARE" "$unit" "$BIN_DIR/viz"; say "removed tviz server (spool ~/.terminal_viz kept)"; return
  fi
  command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }
  mkdir -p "$SHARE/bin" "$BIN_DIR"
  say "fetching server ($REF)"
  for f in server.py index.html bin/viz; do
    curl -fsSL -o "$SHARE/$f" "https://raw.githubusercontent.com/$REPO/$REF/$f"
  done
  chmod +x "$SHARE/bin/viz"; ln -sf "$SHARE/bin/viz" "$BIN_DIR/viz"
  say "python venv with websockets"
  python3 -m venv "$SHARE/venv" && "$SHARE/venv/bin/pip" install -q --disable-pip-version-check 'websockets>=13'
  case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "note: add $BIN_DIR to PATH";; esac
  run="TVIZ_MODE=viz $SHARE/venv/bin/python $SHARE/server.py"
  if ((SERVICE)) && systemctl --user show-environment >/dev/null 2>&1; then
    mkdir -p "$(dirname "$unit")"
    cat >"$unit" <<UNIT
[Unit]
Description=tviz viz server (127.0.0.1:8790)
[Service]
Environment=TVIZ_MODE=viz
ExecStart=$SHARE/venv/bin/python $SHARE/server.py
Restart=on-failure
[Install]
WantedBy=default.target
UNIT
    systemctl --user daemon-reload && systemctl --user enable --now tviz.service
    systemctl --user restart tviz.service
    say "service tviz.service running; survives logout only with: loginctl enable-linger"
  else
    echo "start it yourself: $run"
  fi
  say "done: try  echo '# hi' | viz - hi.md"
}
$ROLE
