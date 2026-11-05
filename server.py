"""Browser terminal plus live visualization pane.

`GET /` serves the page; `WS /pty` runs `CMD` in a pseudo-terminal per connection;
`WS /events` pushes the item list whenever `SPOOL` changes; `GET /items/NAME` serves an item.
Agents publish by dropping files into `SPOOL` (see `bin/viz`).
Auth (all must hold, else 403): header `Tailscale-User-Login` == `TVIZ_LOGIN` (set by Tailscale Serve),
a session cookie obtained once via `GET /login?t=TOKEN` (token in `TOKEN_FILE`, single use, then rotated),
and for websockets `Origin` == `TVIZ_ORIGIN`. Unset `TVIZ_LOGIN`/`TVIZ_ORIGIN` reject everything.
Sessions last `TVIZ_SESSION_S` (default 12h); `GET /logout` ends one; either closes its open websockets.
"""
import asyncio, re, secrets, time, fcntl, json, mimetypes, os, pty, signal, struct, sys, termios
from http import HTTPStatus
from pathlib import Path
from urllib.parse import unquote
from websockets.asyncio.server import serve
from websockets.exceptions import ConnectionClosed
from websockets.datastructures import Headers
from websockets.http11 import Response

ROOT = Path(__file__).resolve().parent
SPOOL = Path(os.environ.get("TVIZ_SPOOL", Path.home() / ".terminal_viz" / "items"))
PORT = int(os.environ.get("TVIZ_PORT", "8790"))
CMD = os.environ.get("TVIZ_CMD", "tmux new-session -A -s tviz ; set-option window-size latest").split()
"""`window-size latest`: a phone attaching must not shrink the desktop view."""
LOGIN = os.environ.get("TVIZ_LOGIN")
ORIGIN = os.environ.get("TVIZ_ORIGIN")
TOKEN_FILE = SPOOL.parent / "login_token"
SESSION_S = float(os.environ.get("TVIZ_SESSION_S", 12 * 3600))
SESSIONS = {}
VIZ_ONLY = os.environ.get("TVIZ_MODE") == "viz"
"""Viz pane only, no terminal and no auth: for `ssh -L` from the human's laptop, like Omnigent's local mode on `6767`."""
LOCAL_ORIGIN = re.compile(r"http://(localhost|127\.0\.0\.1)(:\d+)?|tauri://localhost|http://tauri\.localhost")
"""Any local port: the laptop end of `ssh -L` may differ from `PORT`."""
"""`sid -> expiry` (monotonic seconds)."""


def rotate_token():
    """Write a fresh single-use login token, readable only by this user."""
    TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(TOKEN_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.write(fd, secrets.token_urlsafe(32).encode())
    os.close(fd)


def live(sid):
    """Whether `sid` names an unexpired session; drops it once expired."""
    if sid in SESSIONS and SESSIONS[sid] > time.monotonic():
        return True
    SESSIONS.pop(sid, None)
    return False


def cookie_sid(req):
    for part in req.headers.get("Cookie", "").split(";"):
        k, _, v = part.strip().partition("=")
        if k == "tviz":
            return v
    return None


def items():
    """Newest first: `[{name, mtime}]`."""
    out = []
    for f in SPOOL.iterdir():
        try:
            if not f.name.startswith(".") and f.is_file():
                out.append({"name": f.name, "mtime": f.stat().st_mtime})
        except FileNotFoundError:
            pass
    return sorted(out, key=lambda it: it["mtime"], reverse=True)


def respond(status, body, ctype="text/plain", extra=()):
    hs = [("Content-Type", ctype), ("Content-Length", str(len(body))), ("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff"), *extra]
    return Response(status.value, status.phrase, Headers(hs), body)


def http(conn, req):
    """Auth, then static files; returns `None` to accept websocket paths."""
    path, _, query = req.path.partition("?")
    if VIZ_ONLY:
        if path == "/pty" or path == "/events" and not LOCAL_ORIGIN.fullmatch(req.headers.get("Origin") or ""):
            return respond(HTTPStatus.FORBIDDEN, b"forbidden")
        if path == "/events":
            return None
    else:
        if not LOGIN or req.headers.get("Tailscale-User-Login") != LOGIN:
            return respond(HTTPStatus.FORBIDDEN, b"forbidden")
        if path == "/login":
            token = TOKEN_FILE.read_text()
            if not secrets.compare_digest(query.removeprefix("t="), token):
                return respond(HTTPStatus.FORBIDDEN, b"forbidden")
            rotate_token()
            sid = secrets.token_urlsafe(32)
            SESSIONS[sid] = time.monotonic() + SESSION_S
            r = respond(HTTPStatus.FOUND, b"")
            r.headers["Location"] = "/"
            r.headers["Set-Cookie"] = f"tviz={sid}; HttpOnly; Secure; SameSite=Strict; Path=/"
            return r
        sid = cookie_sid(req)
        if not VIZ_ONLY and not live(sid):
            return respond(HTTPStatus.FORBIDDEN, b"forbidden")
        if path == "/logout":
            SESSIONS.pop(sid)
            return respond(HTTPStatus.OK, b"logged out", extra=[("Set-Cookie", "tviz=; Max-Age=0; HttpOnly; Secure; SameSite=Strict; Path=/")])
        if path in ("/pty", "/events"):
            return None if ORIGIN and req.headers.get("Origin") == ORIGIN else respond(HTTPStatus.FORBIDDEN, b"forbidden")
    if path == "/":
        page = (ROOT / "index.html").read_bytes()
        return respond(HTTPStatus.OK, page.replace(b"<body>", b'<body class="vizonly">') if VIZ_ONLY else page, "text/html; charset=utf-8")
    if path.startswith("/items/"):
        name = unquote(path[len("/items/"):])
        f = SPOOL / name
        if "/" not in name and not name.startswith(".") and f.is_file():
            ctype = mimetypes.guess_type(name)[0] or "text/plain; charset=utf-8"
            return respond(HTTPStatus.OK, f.read_bytes(), ctype, [("Content-Security-Policy", "sandbox allow-scripts")])
    return respond(HTTPStatus.NOT_FOUND, b"not found")


async def run_pty(ws):
    """Bridge one websocket to a fresh pty; text frames `{"cols","rows"}` resize, binary frames are keys."""
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.environ["PATH"] = f"{ROOT / 'bin'}:{os.environ['PATH']}"
        try:
            os.execvp(CMD[0], CMD)
        finally:
            os._exit(127)
    loop = asyncio.get_running_loop()
    out = asyncio.Queue()
    def on_read():
        try:
            out.put_nowait(os.read(fd, 65536))
        except OSError:
            loop.remove_reader(fd)
            out.put_nowait(b"")

    loop.add_reader(fd, on_read)

    async def pump():
        while (data := await out.get()):
            await ws.send(data)
        await ws.close()

    task = asyncio.create_task(pump())
    try:
        async for msg in ws:
            if isinstance(msg, bytes):
                os.write(fd, msg)
            else:
                try:
                    size = json.loads(msg)
                    winsz = struct.pack("HHHH", int(size["rows"]), int(size["cols"]), 0, 0)
                except (ValueError, KeyError, TypeError, struct.error):
                    continue
                fcntl.ioctl(fd, termios.TIOCSWINSZ, winsz)
    except (OSError, ConnectionClosed):
        pass
    finally:
        loop.remove_reader(fd)
        task.cancel()
        os.close(fd)
        os.kill(pid, signal.SIGHUP)
        await asyncio.to_thread(os.waitpid, pid, 0)


async def run_events(ws):
    """Send the item list on connect and on every spool change (polled)."""
    last = None
    try:
        while True:
            cur = items()
            if cur != last:
                await ws.send(json.dumps(cur))
                last = cur
            await asyncio.sleep(0.3)
    except ConnectionClosed:
        pass


async def handler(ws):
    """Run the endpoint; close it once its session expires or logs out (checked every second)."""
    assert not (VIZ_ONLY and ws.request.path.startswith("/pty"))
    sid = cookie_sid(ws.request)
    task = asyncio.create_task((run_pty if ws.request.path.startswith("/pty") else run_events)(ws))
    while not task.done():
        await asyncio.wait([task], timeout=1)
        if not VIZ_ONLY and not live(sid):
            await ws.close(4001, "session ended")
    await task


async def main():
    SPOOL.mkdir(parents=True, exist_ok=True)
    rotate_token()
    async with serve(handler, "127.0.0.1", PORT, process_request=http, max_size=None, compression=None):
        print(f"terminal_viz on http://127.0.0.1:{PORT} spool={SPOOL} cmd={CMD} login={LOGIN} origin={ORIGIN}", file=sys.stderr)
        await asyncio.Future()


asyncio.run(main())
