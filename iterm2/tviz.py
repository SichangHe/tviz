#!/usr/bin/env python3
"""iTerm2 AutoLaunch script: viz pane in the toolbelt (iTerm2's window sidebar).

Shows http://localhost:8790 (the viz server, reached via `ssh -L 8790:127.0.0.1:8790`)
as a toolbelt tool, and opens the toolbelt whenever an agent publishes a new item.
"""
import asyncio
import json

import iterm2
import websockets

URL = "http://localhost:8790/"
EVENTS = "ws://localhost:8790/events"
TOOL_ID = "dev.sichanghe.tviz"
SHOW_TOOLBELT = "Show Toolbelt"


async def reveal(conn):
    await iterm2.tool.async_register_web_view_tool(conn, "viz", TOOL_ID, True, URL)
    state = await iterm2.MainMenu.async_get_menu_item_state(conn, SHOW_TOOLBELT)
    if not state.checked:
        await iterm2.MainMenu.async_select_menu_item(conn, SHOW_TOOLBELT)


async def main(conn):
    await iterm2.tool.async_register_web_view_tool(conn, "viz", TOOL_ID, False, URL)
    seen = None  # newest (name, mtime); first message only sets the baseline
    while True:
        try:
            async with websockets.connect(EVENTS, origin="http://localhost") as ws:
                async for msg in ws:
                    items = json.loads(msg)
                    newest = (items[0]["name"], items[0]["mtime"]) if items else None
                    if seen is not None and newest and newest != seen:
                        await reveal(conn)
                    seen = newest
        except (OSError, websockets.exceptions.WebSocketException):
            pass  # forward down or server restarting
        await asyncio.sleep(2)


iterm2.run_forever(main)
