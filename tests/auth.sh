#!/usr/bin/env bash
# Auth checks against a local server started with
#   TVIZ_LOGIN=me@x TVIZ_ORIGIN=https://h:8443 TVIZ_SESSION_S=4 TVIZ_CMD="bash --norc" python3 server.py
# Every line prints `PASS` or `FAIL`. Synthetic headers only: says nothing about real Tailscale Serve.
# The token never appears on any command line (curl reads it from a config on stdin).
set -u
U="http://127.0.0.1:${TVIZ_PORT:-8790}"; ME='me@x'; TF=~/.terminal_viz/login_token
check() { [[ "$2" == "$3" ]] && echo "PASS $1" || echo "FAIL $1: got $2, want $3"; }
code() { curl -s -o /dev/null -w "%{http_code}" "$@"; }
login() { # $1 = login header; prints session cookie `tviz=...` or nothing
    printf 'url = "%s/login?t=%s"\n' "$U" "$(cat $TF)" | curl -s -D- -o /dev/null -K - -H "Tailscale-User-Login: $1" | grep -o 'tviz=[^;]*'; }
bad_token() { printf 'url = "%s/login?t=nope"\n' "$U" | code -K - -H "Tailscale-User-Login: $ME"; }
ws() { # path origin login cookie -> open|rejected
    timeout 10 python3 - "${U#http://}" "$@" <<'E'
import asyncio, sys, websockets
host, path, origin, login, cookie = sys.argv[1:]
async def m():
    try:
        async with websockets.connect(f"ws://{host}{path}", origin=origin, additional_headers={"Tailscale-User-Login": login, "Cookie": cookie}):
            print("open")
    except websockets.InvalidStatus:
        print("rejected")
asyncio.run(m())
E
}
ws_closed_within() { # path cookie seconds -> closed|open: whether an open socket gets closed
    timeout 20 python3 - "${U#http://}" "$@" <<'E'
import asyncio, sys, websockets
host, path, cookie, secs = sys.argv[1:]
async def m():
    async with websockets.connect(f"ws://{host}{path}", origin="https://h:8443", additional_headers={"Tailscale-User-Login": "me@x", "Cookie": cookie}) as w:
        try:
            async with asyncio.timeout(float(secs)):
                async for _ in w: pass
            print("closed")
        except websockets.ConnectionClosed:
            print("closed")
        except TimeoutError:
            print("open")
asyncio.run(m())
E
}
check "anon /" "$(code "$U/")" 403
check "id without cookie" "$(code -H "Tailscale-User-Login: $ME" "$U/")" 403
check "wrong id with valid token" "$(login evil@x)" ""
check "bad token" "$(bad_token)" 403
SID=$(login $ME)
check "valid login" "${SID:+yes}" yes
check "page with session" "$(code -H "Tailscale-User-Login: $ME" -b "$SID" "$U/")" 200
check "session with wrong id" "$(code -H "Tailscale-User-Login: evil@x" -b "$SID" "$U/")" 403
for p in /pty /events; do
    check "ws $p good" "$(ws $p https://h:8443 $ME "$SID")" open
    check "ws $p wrong origin" "$(ws $p https://h $ME "$SID")" rejected
    check "ws $p no origin port" "$(ws $p https://h:443 $ME "$SID")" rejected
    check "ws $p wrong id" "$(ws $p https://h:8443 evil@x "$SID")" rejected
    check "ws $p no cookie" "$(ws $p https://h:8443 $ME "")" rejected
done
check "logout" "$(code -H "Tailscale-User-Login: $ME" -b "$SID" "$U/logout")" 200
check "after logout" "$(code -H "Tailscale-User-Login: $ME" -b "$SID" "$U/")" 403
S2=$(login $ME)
(sleep 1; code -H "Tailscale-User-Login: $ME" -b "$S2" "$U/logout" >/dev/null) &
check "logout closes open /pty" "$(ws_closed_within /pty "$S2" 3)" closed
S3=$(login $ME)
check "expiry closes open /events" "$(ws_closed_within /events "$S3" 8)" closed
check "expired session rejected" "$(code -H "Tailscale-User-Login: $ME" -b "$S3" "$U/")" 403
