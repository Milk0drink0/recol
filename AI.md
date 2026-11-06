# Recol + AI

Recol is meant to work with whatever AI you use. There are three ways in, from simplest to most
connected.

## 1. Copy as Markdown (works with any AI)

Right-click a clipboard's tab, or empty canvas, and choose **Copy as Markdown**, or press **⌥⌘C**.
That copies the whole clipboard as tidy Markdown: notes in full, plus links, files and comments.
Paste it into ChatGPT, Claude, Gemini or anything else.

## 2. MCP (the AI reads and adds clips by itself)

**MCP** (Model Context Protocol) is the open standard AI apps use to connect to tools on your Mac. You
don't need to know how APIs work. You give your AI app one small piece of config, and from then on you
can just ask it things like:

- "What's on my Research clipboard?"
- "Summarize the PDFs I saved to Recol today."
- "Save these three links to a Recol clipboard called Trip."

**Set it up:** open **Recol › Settings › AI** and click **Copy config**. Then paste it into your AI app:

- **Claude desktop:** Settings › Developer › Edit Config. Paste it into `claude_desktop_config.json`, then restart Claude.
- **Cursor / VS Code / others:** add it to the app's MCP settings, which use the same `mcpServers` format.

```json
{
  "mcpServers": {
    "recol": {
      "command": "/usr/bin/python3",
      "args": ["/Users/YOU/Library/Application Support/Recol/recol-mcp.py"]
    }
  }
}
```

The AI gets five tools:

| Tool | What it does |
|---|---|
| `list_clipboards` | Lists your clipboards |
| `read_clipboard` | Reads every clip on one clipboard as Markdown |
| `search_clips` | Searches across all your clipboards |
| `get_clip` | Gets one clip's contents. Images come back as images, text files as text. |
| `add_to_recol` | Saves a note, link, text or file into a clipboard. The clipboard is created if it doesn't exist. |
| `update_clip` | Renames, comments on or recolors a clip. Ask "give my screenshots descriptive names". Renaming only changes the name in Recol, never the file. |

The server is a single file with no dependencies: `ai/recol-mcp.py` in this repo, which Recol copies
to `~/Library/Application Support/Recol/` every time it starts. It needs the `python3` that comes with
Apple's Command Line Tools. If `/usr/bin/python3` asks you to install them, say yes.

## 3. The inbox (scripts, Shortcuts, other apps)

Anything that can write a file can add to Recol. Write a JSON file into

```
~/Library/Application Support/Recol/inbox/
```

and Recol adds it immediately, or the next time it opens. One object, or an array of them:

```json
{ "note": "# Ideas\n- one\n- two", "clipboard": "Inbox", "from": "My script" }
{ "url": "https://example.com" }
{ "text": "plain text" }
{ "path": "/Users/you/Desktop/photo.jpg" }
{ "action": "update", "id": "<clip id>", "label": "Better name", "comment": "…", "color": "#F2C94C" }
```

`clipboard` is optional. It's the clipboard's name, and Recol creates it if it's missing. `from` is
shown in the confirmation. Write to a `.tmp` file first and rename it to `.json` when you're done,
so Recol never reads a half-written file.

## The data format (for builders)

Everything is plain files in `~/Library/Application Support/Recol/`:

| Path | What |
|---|---|
| `clipboards.json` | All clipboards, clips and settings. Only Recol writes this, so use the inbox to add things. |
| `files/<key>/<name>` | Files that were copied into Recol |
| `links.json` | macOS bookmarks for big files that are *linked*, not copied. Each clip also records `origPath`. |
| `plugins/` | Plugins (see [PLUGINS.md](PLUGINS.md)) |
| `inbox/` | Drop zone for new clips |

In `clipboards.json`, each board is `{ id, name, mood?, sticky?, view, clips: [...], shapes: [...] }`.
`clips` are the things you saved. `shapes` are drawings, arrows and titles from mood boards. Notes
are stored as Markdown.
