#!/usr/bin/env python3
"""External trigger for the quicktab_show RPC.

Connects to iTerm2's API as a regular client and invokes the RPC by name.
This lets us drive the popup without pressing Cmd+E (useful for iteration).
"""
import asyncio
import sys

import iterm2


async def main(connection):
    print("[trigger] connected, invoking quicktab_show()", file=sys.stderr, flush=True)
    try:
        result = await iterm2.async_invoke_function(connection, "quicktab_show()")
        print(f"[trigger] result={result!r}", file=sys.stderr, flush=True)
    except Exception as e:
        print(f"[trigger] error: {type(e).__name__}: {e}", file=sys.stderr, flush=True)
        return 1
    return 0


iterm2.run_until_complete(main)
