# terminal_viz

(authored by agents unless marked 🧑)

🧑 "a seamless experience that is like being in the terminal and using nvim but has abilities to display things like in a browser ... see viz from the agent seamlessly"

one browser page
- left: real terminal (xterm.js ↔ pty running `TVIZ_CMD`, default `tmux new-session -A -s tviz`)
    - run nvim, nvim_omnigent, agents inside as usual
- right: viz pane; newest item auto-opens, older ones are tabs; Alt+V toggles
    - `.html` and `.md` render in sandboxed iframes; `/items/*` carry `CSP: sandbox allow-scripts` so items opened directly cannot reach `/pty`
    - `.html` (sandboxed iframe), `.svg .png .jpg .gif .webp`, `.md`, `.mmd` (mermaid), else plain text
- ≤700px wide: panes stack

🧑 "I use kitty + SSH + tmux + fish + nvim, and the local zulip is not inside SSH, match that workflow"; "Don't support phone"; "Do port forwarding"
- viz-only mode (the default deployment): `TVIZ_MODE=viz python3 server.py`
    - no browser terminal (`/pty` 403), no auth; same trust as Omnigent's local mode on `6767`
        - other users on this host can read the viz list over loopback
    - `/events` only from `http://localhost:*` or `http://127.0.0.1:*` origins
    - laptop: `autossh -M 0 -f -N -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -L 8790:127.0.0.1:8790 HOST`, then a browser tab at `http://localhost:8790`
        - the page reconnects by itself; items published during a drop open once it is back
- 🧑 "I don't like skills. Use getagentsmd"
    - agents find it via `getagentsmd get show_viz`
    - `viz` on PATH via `~/.local/bin/viz`

publish: `bin/viz FILE [NAME]` or `CMD | bin/viz - NAME.ext`
- copies into spool `~/.terminal_viz/items` (atomic rename); same name replaces
- works from any shell, agent, or nvim `:!viz %`

run: `TVIZ_LOGIN=LOGIN TVIZ_ORIGIN=https://HOST:8443 python3 server.py`
- listens on `127.0.0.1:${TVIZ_PORT:-8790}` only; meant behind Tailscale Serve
    - planned route (not deployed): `tailscale serve --bg --https 8443 http://127.0.0.1:8790`
- deps: python3 + `websockets`; page loads xterm/marked/mermaid from jsdelivr, pinned by SRI hashes

auth: all must hold, else 403; details in `server.py` docstring
- `Tailscale-User-Login` header == `TVIZ_LOGIN`
- session cookie (HttpOnly, Secure, SameSite=Strict) from one-time `GET /login?t=TOKEN`
    - token in `~/.terminal_viz/login_token` (0600), rotated on use and on start, never logged
- websockets: `Origin` == `TVIZ_ORIGIN`
- trust boundary
    - header alone is not auth: any local process can reach loopback and forge it
    - token/cookie is the local gate: `~/.terminal_viz` is 0700, token 0600; processes running as this user can read it, but they can already run shells
    - pending until a route exists: verify real Serve strips/overwrites client-sent identity headers (dup/case variants)
    - sessions live in memory without expiry; restart revokes all
- `tests/auth.sh`: rejection matrix

revert: stop `server.py`; delete this dir and `~/.terminal_viz`

## tviz: Kitty replacement (Tauri app, macOS)

🧑 "I want something like a terminal, i.e., Kitty would be replaced"; "more like Tauri than Electron, i.e. reuse the webview the OS gives"; "We can ship HTML to the client instead of PNG"

- `app/`: Tauri 2 app; one window
    - left: xterm.js on a local pty running `$SHELL -l` (like Kitty); ssh/tmux/nvim inside as usual
    - right: viz pane fed by `server.py` (viz-only mode) at `localhost:8790`; HTML is rendered, not rasterized
- build on the Mac (needs Rust + Xcode CLT)
    - `cargo install tauri-cli --version '^2' --locked`
    - `cd app/src-tauri && cargo tauri build` → `target/release/bundle/macos/tviz.app`
    - untested: this Linux host lacks webkit2gtk, so it was never compiled
- viz link: ssh with `-L 8790:127.0.0.1:8790` (or the autossh line above)
- server must allow the app origin `tauri://localhost` (done in `LOCAL_ORIGIN`)
- revert: delete `tviz.app`; keep using Kitty
