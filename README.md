# Recol — the better clipboard

A visual clipboard for your Mac. Drag in links, files, images and notes, arrange them on an
infinite canvas or line them up as a grid or list, and drag them back out into any app.
Built for **in-the-moment organizing**: fast, playful, and out of your way.

- **Clipboards & mood boards.** Free canvas, grid or list, with sorting, tags, snapshots and PDF export.
- **Quick save from anywhere.** Select something in any app and press ⌃⌘C (you can change the shortcut).
  Copy history keeps your last 10 copies.
- **Design mode.** Draw, add lines, arrows, shapes and titles, and group things together.
- **Notes in Markdown.** A tiny editor plus a focus mode.
- **AI-ready.** Copy a board as Markdown, or connect any MCP-capable AI app ([AI.md](AI.md)).
- **Plugins.** Small JavaScript files anyone, or any AI, can write ([PLUGINS.md](PLUGINS.md)).
- **Local-first.** Everything lives in plain files on your Mac. Big files are linked, not copied.

## Build

Requires macOS 12 or later and Apple's Command Line Tools (`xcode-select --install`).

```bash
./build.sh && open build/Recol.app
```

- `recol/index.html` — the whole interface (also runs in a browser, minus the Mac-only features)
- `mac/main.swift` — the native Mac shell: window, storage, drag-out, ⌃⌘C, menu bar, Quick Look, Services
- `build.sh` — builds `build/Recol.app`
- `ai/recol-mcp.py` — MCP server so AI apps can read and add clips
- `recol/plugins/` — example plugins

Clips live in `~/Library/Application Support/Recol/`.

- **AI:** see [AI.md](AI.md). Copy as Markdown, an MCP server (`ai/recol-mcp.py`), and an inbox folder.
- **Plugins:** see [PLUGINS.md](PLUGINS.md). Examples live in `recol/plugins/`.

## Getting around

| | |
|---|---|
| Pan | Two-finger scroll, or hold **Space** and drag |
| Zoom | Pinch, hold **Space** and scroll, or ⌘+ / ⌘− / ⌘0 · ⇧⌘1 to fit |
| Grid | R panel › Canvas, or ⌘' (dots → lines → off) · ⇧⌘' snaps clips to it |
| New note | ⌃⌘N, double-click the canvas, or right-click › New note |
| Quick Look | Tap **Space** with clips selected |
| Home | ⇧⌘H, or the house button: every board, plus search across all clips |
| Rename a clip | ⌥⌘R or right-click › Rename. This only changes the name inside Recol; files keep their names. |
| Group | ⌘G / ⇧⌘G, so grouped things move as one |
| Snapshot | ⌥⌘S, or the R panel. Rearrange freely, then **Revert**. |
| Export PDF | ⌘P, or right-click a board |
| Open a link | Double-click. A single click just selects it, so you can move it. |
| Copy history | Bottom-left clock: your last 10 copies from *any* app. Click one to add it. Password-manager copies are never kept. |
| Close a tab | Hover a tab and click ×. The board stays in Home; click it there to reopen. |
| Lost? | The target button next to the zoom % centers you on everything |
| Design mode (mood boards) | E, then V select · P draw · L line · A arrow · R square · O circle · T title. Hold ⇧ for even shapes or 45° lines. |

You can drag clips out of Recol even while it's behind other windows. Windows on top stay on top
until you click without dragging.

Notes are stored as Markdown (`# title`, `- bullets`, `**bold**`, `*italic*`, `<u>underline</u>`) and drag
out to Finder as `.md` files. On mood boards, drawings, arrows and titles are *shapes*. They stay
out of grid and list views, and strokes that touch merge into one shape.

## ⌃⌘C quick save

By default ⌃⌘C is bound to **Services › Save to Recol**: select text, an image or files in any app
and press ⌃⌘C. macOS hands the selection to Recol directly — no permission, clipboard untouched.
Recol writes the shortcut itself (in the `pbs` preferences domain); you can see or change it in
System Settings › Keyboard › Keyboard Shortcuts › Services. It only fires when something is selected
and the app supports Services (most do).

Settings › Quick save › **How it works › Copy & save** switches to the other approach: Recol presses ⌘C
for you, so it works everywhere and also copies to your clipboard, but it needs Accessibility.

### Making Accessibility stick (Copy & save mode only)


⌃⌘C copies your selection by pressing ⌘C for you, which macOS only allows with
**Accessibility** permission. macOS remembers that permission per *signature*, and an
ad-hoc–signed app gets a new signature on every rebuild, so the permission keeps resetting.

Give Recol a stable signature once:

1. Open **Keychain Access** → menu **Keychain Access › Certificate Assistant › Create a Certificate…**
2. Name: `Recol Dev` · Identity Type: **Self-Signed Root** · Certificate Type: **Code Signing** → Create.
3. Run `./build.sh` again — it prints `signed as "Recol Dev"`.
4. In **System Settings › Privacy & Security › Accessibility**, remove any old Recol entry (−), then
   turn Recol on. From now on rebuilds keep the permission.

## License

Recol is free software under the [GNU AGPL-3.0](LICENSE). You can use, study, change and share it.
If you distribute a modified version, or run one as a service for others, you must share your changes
under the same license.
