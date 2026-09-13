#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Keep the visual prototypes in resources/ up to date.

A learned icon is only useful while it still matches what is on screen. Game
updates re-skin buttons, and some controls look different depending on their own
state, so prototypes need checking and occasionally re-teaching.

    uv run icons.py shot out.png     capture the screen, to pick coordinates from
    uv run icons.py list             what has been learned
    uv run icons.py check [set]      do the stored prototypes still match? <- run after an update
    uv run icons.py learn NAME --region x1,y1,x2,y2
                                     teach an appearance
    uv run icons.py learn NAME --from-ocr TEXT --icon-above
                                     find it by its label first, then teach the icon above it

Stdlib only, so `uv run` needs to resolve nothing; the PEP 723 block above just
pins the interpreter.

Talks to nautilus-mcp over stdio, the same way any MCP client does, so it needs
no privileges the server does not already have.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DEFAULT_BINARY = REPO / "swift/.build/release/nautilus-mcp"
DEFAULT_RESOURCES = REPO / "resources"

# A match this far from where it was taught is suspicious; see `check`.
DRIFT_X, DRIFT_Y = 0.05, 0.07


class Server:
    """A minimal MCP stdio client — spawn, initialize, call tools."""

    def __init__(self, binary: Path, resources: Path, android: str | None):
        argv = [str(binary), "--prototypes", str(resources)]
        if android:
            argv += ["--android", android]
        try:
            self.proc = subprocess.Popen(
                argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, text=True, bufsize=1)
        except FileNotFoundError:
            sys.exit(f"no nautilus-mcp at {binary}\nBuild it: cd swift && swift build -c release")
        self._id = 0
        self._rpc("initialize", {})

    def _rpc(self, method: str, params: dict) -> dict:
        self._id += 1
        self.proc.stdin.write(
            json.dumps({"jsonrpc": "2.0", "id": self._id, "method": method, "params": params}) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        if not line.strip():
            sys.exit("nautilus-mcp exited unexpectedly (is a device attached?)")
        return json.loads(line)

    def call(self, tool: str, args: dict | None = None) -> str:
        reply = self._rpc("tools/call", {"name": tool, "arguments": args or {}})
        if "error" in reply:
            sys.exit(f"{tool}: {reply['error']['message']}")
        content = reply["result"]["content"]
        text = next((b["text"] for b in content if b["type"] == "text"), "")
        if reply["result"].get("isError"):
            sys.exit(text)
        return text

    def call_json(self, tool: str, args: dict | None = None):
        text = self.call(tool, args)
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            sys.exit(f"{tool} did not return JSON:\n{text}")

    def image(self, tool: str, args: dict | None = None) -> bytes | None:
        reply = self._rpc("tools/call", {"name": tool, "arguments": args or {}})
        content = reply.get("result", {}).get("content", [])
        blob = next((b["data"] for b in content if b["type"] == "image"), None)
        return base64.b64decode(blob) if blob else None

    def observe(self) -> str:
        """Capture the device screen; returns the new frame id."""
        text = self.call("android_observe")
        if "frame_id=" not in text:
            sys.exit(f"could not capture a frame: {text}")
        return text.split("frame_id=")[1].split()[0]

    def close(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass


def parse_region(text: str) -> dict:
    try:
        x1, y1, x2, y2 = (float(v) for v in text.split(","))
    except ValueError:
        sys.exit("--region wants four numbers: x1,y1,x2,y2 (normalized 0-1)")
    for value in (x1, y1, x2, y2):
        if not 0.0 <= value <= 1.0:
            sys.exit(f"--region values are normalized 0.0-1.0, got {value}")
    return {"x1": x1, "y1": y1, "x2": x2, "y2": y2}


def centre(box: dict) -> tuple[float, float]:
    return (box["x1"] + box["x2"]) / 2, (box["y1"] + box["y2"]) / 2


# ---------------------------------------------------------------------------


def cmd_shot(server: Server, args) -> int:
    data = server.image("android_observe")
    if not data:
        sys.exit("no image came back")
    Path(args.out).write_bytes(data)
    print(f"wrote {args.out} ({len(data)} bytes)")
    print("Open it, and read coordinates off it as fractions of width and height.")
    return 0


def cmd_list(server: Server, args) -> int:
    text = server.call("visual_list")
    try:
        rows = json.loads(text)
    except json.JSONDecodeError:
        print(text)
        return 0
    print(f"{'prototype':34} {'pos':>4} {'neg':>4} {'aspect':>7}  semantic")
    for row in rows:
        print(f"{row['name']:34} {row['positives']:>4} {row['negatives']:>4} "
              f"{row['aspect']:>7.2f}  {row.get('semantic') or ''}")
    return 0


def cmd_check(server: Server, args) -> int:
    """Do the stored prototypes still match the live screen?

    Run this after a game update. A prototype that no longer matches is not a
    crash — it is a silently wrong tap waiting to happen.
    """
    rows = json.loads(server.call("visual_list"))
    if args.set:
        rows = [r for r in rows if r["name"].startswith(args.set + "/")]
    if not rows:
        print("nothing learned yet" + (f" under {args.set}/" if args.set else ""))
        return 0

    frame = server.observe()
    print(f"checking {len(rows)} prototype(s) against a fresh capture\n")
    print(f"{'prototype':30} {'score':>6} {'margin':>7} {'drift':>13}  verdict")
    stale = 0
    for row in rows:
        result = server.call_json(
            "visual_find", {"prototype": row["name"], "frame_id": frame, "min_score": 0.0})
        if not result.get("matches"):
            print(f"{row['name']:30} {'-':>6} {'-':>7} {'-':>13}  NOT FOUND")
            stale += 1
            continue
        best = result["matches"][0]
        score, margin = best["score"], result.get("margin", 0.0)
        # Judge by WHERE it landed, against where it was taught — not by the
        # absolute score. Scores are relative and vary with what is behind the
        # element; a control over a busy, animated corner scores lower than one
        # on a flat panel while still being located exactly. Scoring alone
        # flagged a prototype "stale" that had landed within 0.002 of the spot
        # it was taught.
        #
        # The search prior is no use for this: it is a padded box that clamps at
        # the frame edge, so near a corner its centre is not the real one.
        taught = row.get("learned_center")
        drift = ""
        if taught:
            cx, cy = best["center"]["x"], best["center"]["y"]
            dx, dy = abs(cx - taught["x"]), abs(cy - taught["y"])
            drift = f"dx{dx:.3f} dy{dy:.3f}"
            if dx > DRIFT_X or dy > DRIFT_Y:
                verdict, stale = "MOVED or mismatched", stale + 1
            elif margin < 0.08:
                verdict = "found, but ambiguous — add a negative"
            else:
                verdict = "ok"
        elif score < args.min_score:
            # No recorded position to check against, so the score is all we have.
            verdict, stale = "STALE — relearn (no taught position on record)", stale + 1
        elif margin < 0.08:
            verdict = "found, but ambiguous — add a negative"
        print(f"{row['name']:30} {score:>6.3f} {margin:>7.3f} {drift:>13}  {verdict}")

    print()
    if stale:
        print(f"{stale} prototype(s) need attention. To re-teach one, find it on screen and:")
        print("  uv run icons.py learn <name> --region x1,y1,x2,y2")
        print("Learning again ADDS an appearance; it does not replace the old one, so a")
        print("prototype can cover several looks of the same control.")
    else:
        print("all prototypes still match.")
    return 1 if stale else 0


def cmd_learn(server: Server, args) -> int:
    frame = server.observe()

    region = None
    if args.region:
        region = parse_region(args.region)
    elif args.from_ocr:
        # Bootstrap: read the screen to find the thing, once. After this the
        # appearance is what gets used, not the text.
        band = parse_region(args.ocr_region) if args.ocr_region else \
            {"x1": 0.0, "y1": 0.0, "x2": 1.0, "y2": 1.0}
        found = server.call_json(
            "image_ocr", {"frame_id": frame, "region": band, "languages": ["ja", "en-US"]})
        hits = [i for i in found.get("items", []) if args.from_ocr in i["text"]]
        if not hits:
            seen = ", ".join(i["text"] for i in found.get("items", [])[:12])
            sys.exit(f"OCR did not find {args.from_ocr!r}. It read: {seen}\n"
                     "This game's stylized text OCRs poorly — pass --region instead.")
        label = hits[0]["bbox"]
        cx, _ = centre(label)
        if args.icon_above:
            # An icon sits above its label; take a box of --icon-size centred on
            # the label's x, ending just above the label's top.
            half = args.icon_size / 2
            top = max(0.0, label["y1"] - args.icon_size - 0.005)
            region = {"x1": round(cx - half, 4), "y1": round(top, 4),
                      "x2": round(cx + half, 4), "y2": round(label["y1"] - 0.005, 4)}
        else:
            region = label
        print(f"OCR found {hits[0]['text']!r}; learning region "
              f"{json.dumps(region, ensure_ascii=False)}")
    else:
        sys.exit("give --region x1,y1,x2,y2, or --from-ocr TEXT")

    text = server.call("visual_learn", {
        "frame_id": frame, "name": args.name, "region": region,
        "semantic": args.semantic, "kind": args.kind,
        **({"as": "negative"} if args.negative else {})})
    print(text)

    if args.negative:
        return 0

    # Verify on a NEW capture, not the one it was taught from — otherwise the
    # check is circular and proves nothing.
    print("\nverifying against a fresh capture...")
    server.call("android_wait", {"seconds": 1})
    fresh = server.observe()
    result = server.call_json(
        "visual_find", {"prototype": args.name, "frame_id": fresh, "min_score": 0.0})
    if not result.get("matches"):
        print("FAILED: could not find it again. Try a tighter region around the icon itself.")
        return 1
    best = result["matches"][0]
    wx, wy = centre(region)
    cx, cy = best["center"]["x"], best["center"]["y"]
    dx, dy = abs(cx - wx), abs(cy - wy)
    print(f"  score {best['score']:.3f}  margin {result.get('margin', 0):.3f}  "
          f"found at ({cx:.3f}, {cy:.3f}) vs taught ({wx:.3f}, {wy:.3f})  "
          f"error dx={dx:.3f} dy={dy:.3f}")
    if dx < DRIFT_X and dy < DRIFT_Y and best["score"] >= args.min_score:
        print("  OK — it finds itself.")
        return 0
    print("  WEAK. Either teach it again from another screen (positives accumulate),")
    print("  or teach the look-alike it is confusing itself with:")
    print(f"    icons.py learn {args.name} --region <look-alike> --negative")
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--binary", default=str(DEFAULT_BINARY), help="path to nautilus-mcp")
    parser.add_argument("--resources", default=str(DEFAULT_RESOURCES), help="prototype store")
    parser.add_argument("--android", default=None, help="device serial, or 'auto'")
    parser.add_argument("--min-score", type=float, default=0.25,
                        help="below this a match is considered stale (default 0.25)")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("shot", help="capture the screen to a PNG")
    p.add_argument("out", nargs="?", default="screen.png")
    p.set_defaults(func=cmd_shot)

    p = sub.add_parser("list", help="what has been learned")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("check", help="do the stored prototypes still match?")
    p.add_argument("set", nargs="?", help="only this set, e.g. farlight_cod")
    p.set_defaults(func=cmd_check)

    p = sub.add_parser("learn", help="teach an appearance")
    p.add_argument("name", help="prototype id, e.g. farlight_cod/march_button")
    p.add_argument("--region", help="x1,y1,x2,y2 normalized")
    p.add_argument("--from-ocr", help="find the element by its text first")
    p.add_argument("--ocr-region", help="limit the OCR search to x1,y1,x2,y2")
    p.add_argument("--icon-above", action="store_true",
                   help="with --from-ocr: learn the icon above the label, not the label")
    p.add_argument("--icon-size", type=float, default=0.07,
                   help="height of the icon box for --icon-above (default 0.07)")
    p.add_argument("--semantic", help="what it means, e.g. 進軍 (recorded, never matched on)")
    p.add_argument("--kind", default="icon", help="button, icon, panel, badge…")
    p.add_argument("--negative", action="store_true",
                   help="teach this as a look-alike to REJECT, not to match")
    p.set_defaults(func=cmd_learn)

    args = parser.parse_args()
    server = Server(Path(args.binary), Path(args.resources), args.android)
    try:
        return args.func(server, args)
    finally:
        server.close()


if __name__ == "__main__":
    sys.exit(main())
