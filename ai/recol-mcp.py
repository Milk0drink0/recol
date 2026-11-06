#!/usr/bin/env python3
"""Recol MCP server — lets AI apps (Claude, ChatGPT, Cursor, VS Code, …) read and add to your Recol clipboards.

MCP (Model Context Protocol) is the open standard AI apps use to talk to local tools. This file is the whole
server: no installs, no dependencies, just the Python that ships with macOS. The AI app starts it and talks to it
over stdin/stdout.

    {"mcpServers": {"recol": {"command": "/usr/bin/python3",
                              "args": ["~/Library/Application Support/Recol/recol-mcp.py"]}}}

Reading goes straight to Recol's data file. Adding goes through Recol's inbox folder, so the app stays the only
thing that writes your clipboards (if Recol isn't running, new clips appear the next time it opens).
"""
import base64, json, mimetypes, os, sys, time, uuid

SUPPORT = os.path.expanduser("~/Library/Application Support/Recol")
STATE = os.path.join(SUPPORT, "clipboards.json")
FILES = os.path.join(SUPPORT, "files")
INBOX = os.path.join(SUPPORT, "inbox")
TEXT_EXT = {"txt", "md", "markdown", "csv", "tsv", "json", "xml", "html", "htm", "css", "js", "ts", "py", "rb", "swift", "java",
            "c", "h", "cpp", "go", "rs", "sh", "yml", "yaml", "toml", "ini", "log", "svg", "tex", "rtf"}
MAX_TEXT = 200_000
MAX_IMAGE = 5_000_000


# ───────────────────────── reading Recol's data ─────────────────────────

TAGS = {}


def load():
    global TAGS
    try:
        with open(STATE, encoding="utf-8") as f:
            st = json.load(f)
            TAGS = {t.get("id"): t.get("name") for t in st.get("tags") or []}
            return st
    except FileNotFoundError:
        raise ToolError("Recol has no clipboards yet — open Recol once first.")


def boards(state):
    return state.get("boards") or []


def find_board(state, ref):
    bs = boards(state)
    if not ref:
        return next((b for b in bs if b.get("id") == state.get("current")), bs[0] if bs else None)
    r = str(ref).strip().lower()
    return next((b for b in bs if b.get("id") == ref or str(b.get("name", "")).lower() == r), None)


def file_path(c):
    """Where the real file behind a clip lives (a copy inside Recol, or the linked original)."""
    if not c.get("blobKey"):
        return None
    if c.get("ref"):
        return c.get("origPath")
    p = os.path.join(FILES, c["blobKey"], c.get("fileName") or "")
    return p if os.path.exists(p) else None


def clip_name(c):
    if c.get("label"):          # renamed inside Recol (the file on disk keeps its real name)
        return c["label"]
    if c.get("type") == "link":
        return c.get("url", "")
    if c.get("type") == "text":
        first = next((l for l in (c.get("text") or "").splitlines() if l.strip()), "")
        return first.lstrip("#-* ").strip()[:80] or "Note"
    return c.get("name") or "Untitled"


def kind(c):
    t = c.get("type")
    return {"text": "note", "link": "link", "image": "image", "video": "video"}.get(t, (c.get("ext") or "file") + " file")


def describe(c, full=True):
    """One clip as Markdown."""
    t = c.get("type")
    head = f"- **{clip_name(c)}** · {kind(c)} · id `{c.get('id')}`"
    extra = []
    if c.get("sticky"):
        extra.append("sticky")
    if c.get("comment"):
        extra.append(f"comment: “{c['comment']}”")
    if c.get("tags"):
        extra.append("tags: " + ", ".join(TAGS.get(t, "?") for t in c["tags"]))
    if c.get("label") and c.get("name"):
        extra.append(f"file name: {c['name']}")
    if extra:
        head += " · " + ", ".join(extra)
    if t == "text":
        body = (c.get("text") or "").strip()
        if not full and len(body) > 300:
            body = body[:300] + "…"
        return head + "\n\n" + "\n".join("  " + l for l in body.splitlines()) + "\n"
    if t == "link":
        return head + f"\n  {c.get('url')}\n"
    p = file_path(c)
    if p:
        return head + f"\n  file: {p}\n"
    if c.get("url"):
        return head + f"\n  {c['url']}\n"
    return head + "\n"


def board_md(b, full=True):
    clips = sorted(b.get("clips") or [], key=lambda c: c.get("added") or 0)
    out = [f"# {b.get('name')}", f"_{len(clips)} clip{'s' if len(clips) != 1 else ''}{' · mood board' if b.get('mood') else ''} · id `{b.get('id')}`_", ""]
    titles = [s.get("text") for s in (b.get("shapes") or []) if s.get("title") and s.get("text")]
    if titles:
        out += ["Titles on the board: " + " · ".join(titles), ""]
    out += [describe(c, full) for c in clips] or ["(empty)"]
    return "\n".join(out)


# ───────────────────────── tools ─────────────────────────

class ToolError(Exception):
    pass


def t_list_clipboards(args):
    st = load()
    lines = ["Recol clipboards:"]
    for b in boards(st):
        n = len(b.get("clips") or [])
        cur = " (open now)" if b.get("id") == st.get("current") else ""
        lines.append(f"- {b.get('name')} — {n} clip{'s' if n != 1 else ''}{', mood board' if b.get('mood') else ''}{cur} · id `{b.get('id')}`")
    return text("\n".join(lines))


def t_read_clipboard(args):
    st = load()
    b = find_board(st, args.get("clipboard"))
    if not b:
        raise ToolError(f"No clipboard called “{args.get('clipboard')}”. Use list_clipboards to see them.")
    return text(board_md(b))


def t_search_clips(args):
    q = str(args.get("query") or "").strip().lower()
    if not q:
        raise ToolError("Give a query.")
    hits = []
    for b in boards(load()):
        for c in b.get("clips") or []:
            hay = " ".join(str(c.get(k) or "") for k in ("text", "url", "name", "comment", "ext")).lower()
            if q in hay:
                hits.append(f"[{b.get('name')}] " + describe(c, full=False))
    return text(f"{len(hits)} match{'es' if len(hits) != 1 else ''} for “{q}”:\n\n" + "\n".join(hits[:60]) if hits else f"No clips match “{q}”.")


def t_get_clip(args):
    cid = args.get("id")
    for b in boards(load()):
        for c in (b.get("clips") or []) + (b.get("shapes") or []):
            if c.get("id") != cid:
                continue
            content = [{"type": "text", "text": f"From “{b.get('name')}”\n\n" + describe(c)}]
            p = file_path(c)
            if p and os.path.isfile(p):
                mime = c.get("mime") or mimetypes.guess_type(p)[0] or ""
                size = os.path.getsize(p)
                ext = os.path.splitext(p)[1].lstrip(".").lower()
                if mime.startswith("image/") and mime != "image/svg+xml" and size <= MAX_IMAGE:
                    with open(p, "rb") as f:
                        content.append({"type": "image", "data": base64.b64encode(f.read()).decode(), "mimeType": mime})
                elif mime.startswith("text/") or ext in TEXT_EXT:
                    with open(p, encoding="utf-8", errors="replace") as f:
                        body = f.read(MAX_TEXT + 1)
                    content.append({"type": "text", "text": body[:MAX_TEXT] + ("\n…(truncated)" if len(body) > MAX_TEXT else "")})
                else:
                    content.append({"type": "text", "text": f"(A {ext or 'binary'} file, {size:,} bytes — open it from the path above with a tool that understands it.)"})
            return {"content": content}
    raise ToolError(f"No clip with id {cid}.")


def t_add_to_recol(args):
    entries = []
    base = {"from": args.get("from") or "Your AI"}
    if args.get("clipboard"):
        base["clipboard"] = str(args["clipboard"])
    if args.get("note"):
        entries.append({**base, "note": str(args["note"])})
    if args.get("text"):
        entries.append({**base, "text": str(args["text"])})
    for u in [args["url"]] if isinstance(args.get("url"), str) else args.get("url") or []:
        entries.append({**base, "url": str(u)})
    for p in [args["file_path"]] if isinstance(args.get("file_path"), str) else args.get("file_path") or []:
        full = os.path.abspath(os.path.expanduser(str(p)))
        if not os.path.exists(full):
            raise ToolError(f"There's no file at {full}")
        entries.append({**base, "path": full})
    if not entries:
        raise ToolError("Give a note, text, url or file_path to add.")
    write_inbox(entries)
    where = f"the “{base['clipboard']}” clipboard" if "clipboard" in base else "Recol"
    return text(f"Added {len(entries)} clip{'s' if len(entries) != 1 else ''} to {where}. (If Recol isn't open, they'll appear when it starts.)")


def t_update_clip(args):
    cid = str(args.get("id") or "")
    if not cid:
        raise ToolError("Give the clip's id (from read_clipboard or search_clips).")
    if not any(c.get("id") == cid for b in boards(load()) for c in (b.get("clips") or [])):
        raise ToolError(f"No clip with id {cid}.")
    op = {"action": "update", "id": cid, "from": args.get("from") or "Your AI"}
    for src, dst in (("name", "label"), ("comment", "comment"), ("color", "color")):
        if src in args:
            op[dst] = args[src]
    if len(op) == 3:
        raise ToolError("Give a name, comment or color to change.")
    write_inbox([op])
    return text(f"Updated clip {cid}. Renaming only changes its name inside Recol — files on disk keep their names.")


def write_inbox(entries):
    os.makedirs(INBOX, exist_ok=True)
    name = f"{int(time.time() * 1000)}-{uuid.uuid4().hex[:8]}"
    tmp = os.path.join(INBOX, name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(entries, f)
    os.replace(tmp, os.path.join(INBOX, name + ".json"))   # Recol only picks up finished .json files


def text(s):
    return {"content": [{"type": "text", "text": s}]}


TOOLS = [
    {"name": "list_clipboards", "description": "List the user's Recol clipboards (boards of saved clips) with how many clips each has.",
     "inputSchema": {"type": "object", "properties": {}}, "fn": t_list_clipboards},
    {"name": "read_clipboard", "description": "Read every clip on one Recol clipboard as Markdown: notes in full, links, and file paths. Defaults to the clipboard open in Recol right now.",
     "inputSchema": {"type": "object", "properties": {"clipboard": {"type": "string", "description": "Clipboard name or id. Optional."}}},
     "fn": t_read_clipboard},
    {"name": "search_clips", "description": "Search all Recol clipboards for clips whose text, link, file name or comment contains the query.",
     "inputSchema": {"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]}, "fn": t_search_clips},
    {"name": "get_clip", "description": "Get one clip by id, including its contents: images come back as images, text-like files as text.",
     "inputSchema": {"type": "object", "properties": {"id": {"type": "string"}}, "required": ["id"]}, "fn": t_get_clip},
    {"name": "add_to_recol", "description": "Save something into Recol as a new clip: a Markdown note, a link, plain text, or a file on disk. Optionally into a named clipboard (created if missing).",
     "inputSchema": {"type": "object", "properties": {
         "note": {"type": "string", "description": "A note, in Markdown (# title, - bullets, **bold**, *italic*)."},
         "text": {"type": "string", "description": "Plain text. A bare URL becomes a link clip."},
         "url": {"anyOf": [{"type": "string"}, {"type": "array", "items": {"type": "string"}}]},
         "file_path": {"anyOf": [{"type": "string"}, {"type": "array", "items": {"type": "string"}}], "description": "Absolute path(s) to files to add."},
         "clipboard": {"type": "string", "description": "Name of the clipboard to add to. Optional."}}},
     "fn": t_add_to_recol},
    {"name": "update_clip", "description": "Rename, comment on, or recolor a clip, to help the user organize. Renaming only changes the name shown in Recol, never the file on disk.",
     "inputSchema": {"type": "object", "properties": {
         "id": {"type": "string"}, "name": {"type": "string", "description": "New display name. Empty string restores the original."},
         "comment": {"type": "string"}, "color": {"type": "string", "description": "Hex color like #6BBFE0."}}, "required": ["id"]},
     "fn": t_update_clip},
]


# ───────────────────────── JSON-RPC over stdio ─────────────────────────

def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def handle(req):
    method, rid, params = req.get("method"), req.get("id"), req.get("params") or {}
    if method == "initialize":
        return {"protocolVersion": params.get("protocolVersion") or "2025-06-18", "capabilities": {"tools": {}},
                "serverInfo": {"name": "recol", "version": "1.0.0"},
                "instructions": "Recol is the user's visual clipboard. Clips are saved links, notes, images and files grouped into clipboards. Use read_clipboard to see what the user collected, get_clip for a file's contents, and add_to_recol to save results back for them."}
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": [{k: v for k, v in t.items() if k != "fn"} for t in TOOLS]}
    if method == "tools/call":
        tool = next((t for t in TOOLS if t["name"] == params.get("name")), None)
        if not tool:
            raise LookupError(f"Unknown tool {params.get('name')}")
        try:
            return tool["fn"](params.get("arguments") or {})
        except ToolError as e:
            return {"content": [{"type": "text", "text": str(e)}], "isError": True}
    if rid is None:
        return None   # a notification (e.g. notifications/initialized) — nothing to answer
    raise LookupError(f"Method not found: {method}")


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError:
            send({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}})
            continue
        rid = req.get("id")
        try:
            result = handle(req)
            if rid is not None:
                send({"jsonrpc": "2.0", "id": rid, "result": result})
        except LookupError as e:
            if rid is not None:
                send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": str(e)}})
        except Exception as e:  # never crash the AI app's connection
            if rid is not None:
                send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": f"{type(e).__name__}: {e}"}})


if __name__ == "__main__":
    main()
