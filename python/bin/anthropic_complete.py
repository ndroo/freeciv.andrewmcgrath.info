#!/usr/bin/env python3
"""Stream a single Anthropic Messages API call and emit the text content.

Streams the response so the caller sees live progress (tokens/second,
elapsed time) on stderr while the model writes the response. The final
assembled text content is printed to stdout — drop-in replacement for
`curl ... | jq -r '.content[0].text'` in shell scripts that don't want
to wait blind for 2-3 minutes.

Usage:
  anthropic_complete.py <system_prompt_file> <user_prompt_file> \
      [--model claude-opus-4-6] [--max-tokens 8000] [--temperature 0.9]

Env:
  ANTHROPIC_API_KEY   required

Exit codes:
  0  success — final content written to stdout
  1  API/transport error — diagnostics on stderr
  2  bad arguments
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.request
import urllib.error


API_URL = "https://api.anthropic.com/v1/messages"
ANTHROPIC_VERSION = "2023-06-01"


def _emit_progress(out_tokens: int, elapsed: float, last_emit: dict) -> None:
    """Print a one-line heartbeat to stderr at most once per second.

    The caller's terminal will see a steady tick rather than 2-3 minutes
    of dead air. We use `last_emit` as a tiny mutable cache to throttle.
    """
    now = time.monotonic()
    if now - last_emit.get("at", 0.0) < 1.0:
        return
    rate = out_tokens / elapsed if elapsed > 0 else 0.0
    sys.stderr.write(
        f"\r[anthropic] streaming… {out_tokens:>5} tok / {elapsed:>5.1f}s "
        f"({rate:>4.0f} tok/s)"
    )
    sys.stderr.flush()
    last_emit["at"] = now


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("system_file")
    parser.add_argument("user_file")
    parser.add_argument("--model", default="claude-opus-4-6")
    parser.add_argument("--max-tokens", type=int, default=8000)
    parser.add_argument("--temperature", type=float, default=0.9)
    args = parser.parse_args()

    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        print("[anthropic_complete] ANTHROPIC_API_KEY not set", file=sys.stderr)
        return 2

    with open(args.system_file, encoding="utf-8") as f:
        system = f.read()
    with open(args.user_file, encoding="utf-8") as f:
        user = f.read()

    body = {
        "model": args.model,
        "max_tokens": args.max_tokens,
        "temperature": args.temperature,
        "system": system,
        "messages": [{"role": "user", "content": user}],
        "stream": True,
    }

    req = urllib.request.Request(
        API_URL,
        data=json.dumps(body).encode("utf-8"),
        headers={
            "x-api-key": api_key,
            "anthropic-version": ANTHROPIC_VERSION,
            "Content-Type": "application/json",
        },
        method="POST",
    )

    sys.stderr.write(
        f"[anthropic] streaming via {args.model} "
        f"(system={len(system)}B, user={len(user)}B, max_tokens={args.max_tokens})\n"
    )
    sys.stderr.flush()

    started = time.monotonic()
    last_emit: dict = {}
    out_tokens = 0
    pieces: list[str] = []
    stop_reason: str | None = None
    final_usage: dict | None = None

    try:
        with urllib.request.urlopen(req, timeout=600) as resp:
            # The streaming response is SSE: alternating `event: ...` and
            # `data: {...}` lines, separated by blank lines. urllib gives
            # us byte iteration; decode on the fly.
            for raw in resp:
                line = raw.decode("utf-8", errors="replace").rstrip("\r\n")
                if not line.startswith("data: "):
                    continue
                payload = line[len("data: "):]
                if not payload or payload == "[DONE]":
                    continue
                try:
                    msg = json.loads(payload)
                except json.JSONDecodeError:
                    continue

                t = msg.get("type")
                if t == "content_block_delta":
                    delta = msg.get("delta") or {}
                    if delta.get("type") == "text_delta":
                        text = delta.get("text", "")
                        pieces.append(text)
                        # Approximate token count by splitting on whitespace
                        # and punctuation; close enough for a progress meter.
                        out_tokens += max(1, len(text.split()))
                        elapsed = time.monotonic() - started
                        _emit_progress(out_tokens, elapsed, last_emit)
                elif t == "message_delta":
                    delta = msg.get("delta") or {}
                    if "stop_reason" in delta:
                        stop_reason = delta["stop_reason"]
                    if "usage" in msg:
                        final_usage = msg["usage"]
                elif t == "message_stop":
                    pass
                elif t == "error":
                    err = msg.get("error") or {}
                    sys.stderr.write(
                        f"\n[anthropic] error event: {err.get('type','?')} — "
                        f"{err.get('message','')}\n"
                    )
                    return 1
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        sys.stderr.write(f"\n[anthropic] HTTP {e.code} — {e.reason}\n{body[:1500]}\n")
        return 1
    except urllib.error.URLError as e:
        sys.stderr.write(f"\n[anthropic] transport error: {e}\n")
        return 1

    elapsed = time.monotonic() - started
    final_text = "".join(pieces)

    # Final progress line — overwrite the in-flight one and add a newline.
    sys.stderr.write(
        f"\r[anthropic] done in {elapsed:.1f}s — {out_tokens} tokens "
        f"({len(final_text)} chars), stop_reason={stop_reason}"
    )
    if final_usage:
        sys.stderr.write(
            f", input={final_usage.get('input_tokens','?')} "
            f"output={final_usage.get('output_tokens','?')}"
        )
    sys.stderr.write("\n")

    sys.stdout.write(final_text)
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
