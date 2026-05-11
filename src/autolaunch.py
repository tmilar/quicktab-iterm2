#!/usr/bin/env python3
"""
quicktab-iterm2 — iTerm2 AutoLaunch RPC script.

Registers `quicktab_show()` which the user binds to a hotkey via
iTerm2 → Settings → Keys → Key Bindings → Invoke Script Function.

Press the hotkey → popup picker appears with all tabs across all windows.

Logging:
  - default: silent (errors only)
  - QUICKTAB_DEBUG=1 in env: full diagnostic log to /tmp/quicktab-debug.log
"""
import asyncio
import json
import os
import signal
import sys
import time

import iterm2

PICKER_PATH = os.path.expanduser("~/.local/bin/quicktab-picker")
PIDFILE = "/tmp/quicktab-picker.pid"
DEBUG = os.environ.get("QUICKTAB_DEBUG") == "1"
DEBUG_LOG = "/tmp/quicktab-debug.log"


def log(msg: str, *, level: str = "debug") -> None:
    """Write to stderr (captured by iTerm2 Console) and optionally a file.
    Verbose messages are gated by QUICKTAB_DEBUG=1; errors always print."""
    if level == "debug" and not DEBUG:
        return
    line = f"[quicktab {time.strftime('%H:%M:%S')}] {msg}"
    print(line, file=sys.stderr, flush=True)
    if DEBUG:
        try:
            with open(DEBUG_LOG, "a") as f:
                f.write(line + "\n")
        except OSError:
            pass


def kill_existing_picker() -> bool:
    """If a picker is running per pidfile, SIGTERM and return True (toggle close)."""
    try:
        with open(PIDFILE) as f:
            pid = int(f.read().strip())
    except (FileNotFoundError, ValueError):
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        try:
            os.unlink(PIDFILE)
        except OSError:
            pass
        return False
    try:
        os.kill(pid, signal.SIGTERM)
        log(f"toggle close: SIGTERM pid={pid}")
    except OSError as e:
        log(f"failed to terminate {pid}: {e}", level="error")
    try:
        os.unlink(PIDFILE)
    except OSError:
        pass
    return True


async def get_tab_title(tab) -> str:
    session = tab.current_session
    if session is None:
        return "untitled"
    for var in ("autoName", "session.name", "name", "session.tty"):
        try:
            value = await session.async_get_variable(var)
            if value:
                return str(value)
        except Exception:
            continue
    return "untitled"


async def get_tab_tty(tab) -> str | None:
    session = tab.current_session
    if session is None:
        return None
    try:
        tty = await session.async_get_variable("session.tty")
        return tty if tty else None
    except Exception:
        return None


def stat_tty_activity(tty_path: str | None) -> float | None:
    """Return last user-interaction time (epoch seconds) for a tty device.

    On macOS, /dev/ttysN character devices have:
      - mtime: last WRITE (output displayed) — noisy: prompt redraws, escape
        sequences, status updates all bump it without user activity
      - atime: last READ (shell read user's input) — only updates on real
        user interaction

    We use atime for trustworthy "user touched this tab" staleness signal.
    """
    if not tty_path:
        return None
    try:
        return os.stat(tty_path).st_atime
    except OSError:
        return None


async def collect_tabs(app):
    items = []
    current_window_id = (
        app.current_terminal_window.window_id if app.current_terminal_window else None
    )
    log(f"collect_tabs: {len(app.terminal_windows)} window(s), focused={current_window_id}")
    for window in app.terminal_windows:
        active_tab_id = window.current_tab.tab_id if window.current_tab else None
        for idx, tab in enumerate(window.tabs):
            title = await get_tab_title(tab)
            tty = await get_tab_tty(tab)
            last_activity = stat_tty_activity(tty)
            items.append({
                "window_id": window.window_id,
                "tab_id": tab.tab_id,
                "title": title,
                "tab_index": idx + 1,
                "is_active_tab": tab.tab_id == active_tab_id,
                "is_active_window": window.window_id == current_window_id,
                "last_activity_at": last_activity,
            })
    log(f"collect_tabs: {len(items)} tabs total")
    return items


async def get_anchor_frame(app):
    window = app.current_terminal_window
    if window is None:
        return None
    try:
        frame = await window.async_get_frame()
        return {
            "x": int(frame.origin.x),
            "y": int(frame.origin.y),
            "w": int(frame.size.width),
            "h": int(frame.size.height),
        }
    except Exception as e:
        log(f"get_anchor_frame failed: {e}", level="error")
        return None


async def activate(app, window_id: str, tab_id: str) -> None:
    for window in app.terminal_windows:
        if window.window_id != window_id:
            continue
        for tab in window.tabs:
            if tab.tab_id == tab_id:
                await tab.async_select()
                await window.async_activate()
                return


async def close_tab(app, window_id: str, tab_id: str) -> None:
    for window in app.terminal_windows:
        if window.window_id != window_id:
            continue
        for tab in window.tabs:
            if tab.tab_id == tab_id:
                try:
                    await tab.async_close(force=True)
                    log(f"closed tab {tab_id}")
                except Exception as e:
                    log(f"close tab failed: {e}", level="error")
                return
    log(f"close: tab not found ({window_id}/{tab_id})")


async def run_picker(app, payload: bytes) -> None:
    """Spawn picker, stream JSON events from its stdout, dispatch each.

    Protocol (newline-delimited JSON):
      - {"event": "close", "window_id":"X", "tab_id":"Y"} — close, picker stays open
      - {"event": "select", "window_id":"X", "tab_id":"Y"} — activate tab, picker exits
      - EOF without select = user cancelled (Esc / click-outside)
    """
    log(f"spawn picker: {PICKER_PATH} (payload {len(payload)} bytes)")
    try:
        # start_new_session: decouple from iTerm2's process tree so the picker
        # gets its own session and macOS treats it as an independent app
        # rather than a background helper.
        proc = await asyncio.create_subprocess_exec(
            PICKER_PATH,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            start_new_session=True,
        )
    except Exception as e:
        log(f"spawn failed: {e}", level="error")
        return
    log(f"spawn ok: pid={proc.pid}")

    try:
        proc.stdin.write(payload)
        await proc.stdin.drain()
        proc.stdin.close()
    except Exception as e:
        log(f"stdin write failed: {e}", level="error")
        proc.kill()
        return

    try:
        async for raw_line in proc.stdout:
            line = raw_line.decode(errors="replace").strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                log(f"bad picker stdout line: {line!r}", level="error")
                continue
            kind = event.get("event")
            wid = event.get("window_id", "")
            tid = event.get("tab_id", "")
            if kind == "close":
                log(f"event: close window={wid} tab={tid}")
                await close_tab(app, wid, tid)
            elif kind == "select":
                log(f"event: select window={wid} tab={tid}")
                await activate(app, wid, tid)
            else:
                log(f"unknown event: {event}", level="error")
    except asyncio.CancelledError:
        proc.kill()
        return

    try:
        stderr = await proc.stderr.read()
        if stderr and DEBUG:
            for line in stderr.decode(errors="replace").splitlines():
                if line.strip():
                    log(f"picker stderr> {line}")
    except Exception:
        pass

    await proc.wait()
    log(f"picker exited rc={proc.returncode}")


async def main(connection):
    app = await iterm2.async_get_app(connection)
    log("ready", level="info")  # always print: confirms script loaded

    # Debounce: iTerm2 sometimes broadcasts a single keypress to multiple
    # sessions, firing the RPC many times in a burst. Drop anything within
    # this window of the last accepted call. 800ms is generous enough to
    # absorb finger-drumming on the chord without breaking real toggle-close.
    DEBOUNCE_S = 0.8
    last_accepted = [0.0]

    @iterm2.RPC
    async def quicktab_show():
        now = time.monotonic()
        if now - last_accepted[0] < DEBOUNCE_S:
            log("debounced")
            return
        last_accepted[0] = now

        log("invoked")
        if kill_existing_picker():
            log("toggled closed")
            return

        tabs = await collect_tabs(app)
        if not tabs:
            return
        anchor = await get_anchor_frame(app)
        payload = json.dumps({"tabs": tabs, "anchor": anchor}).encode()

        # Fire-and-forget: returns from RPC in <100ms so iTerm2 doesn't fire
        # spurious "Timeout" popups while the user reads the picker.
        asyncio.create_task(run_picker(app, payload))

    await quicktab_show.async_register(connection)
    log("registered quicktab_show", level="info")


iterm2.run_forever(main)
