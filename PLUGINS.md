# Recol plugins

A plugin adds commands to Recol: they appear when you right-click clips, when you right-click the
canvas, and in the **R** panel. Plugins are small, readable JavaScript files, built for in-the-moment
jobs like tidying a board, turning clips into something, or adding a note fast.

> **Have an AI write one.** Paste this whole file into your AI chat and describe the plugin you want.
> It has everything the AI needs.

## Where plugins live

```
~/Library/Application Support/Recol/plugins/
  my-plugin/
    plugin.json
    main.js
```

To install one, drop its folder into `plugins/` (**Settings › Plugins › Open plugins folder**), then
click **Reload plugins**. Use the switches in Settings to turn plugins on and off.

**`plugin.json`**

```json
{
  "name": "My plugin",
  "description": "One line about what it does.",
  "version": "1.0",
  "author": "You",
  "main": "main.js"
}
```

The folder name is the plugin's id. Use letters, numbers, `-`, `_` or `.`.

**`main.js`** runs once when Recol loads. It gets one variable, `recol`, which is the whole API:

```js
recol.command({
  id: 'hello',
  title: 'Say hello',
  where: 'board',                // 'board' (canvas right-click + R panel), 'clip' (clip right-click), or 'both'
  run(ctx) {
    recol.toast(`Hello from ${ctx.board.name}!`);
  }
});
```

## The `recol` API

### Reading

| Call | Returns |
|---|---|
| `recol.boards()` | `[{ id, name, mood, clips, current }]`: every clipboard (`clips` is a count) |
| `recol.board()` | `{ id, name, mood, view, sticky }` for the open clipboard |
| `recol.clips(board?)` | Copies of the clips on a clipboard (default: the open one). Pass a name or id. |
| `recol.shapes(board?)` | Drawings, arrows and titles on a clipboard |
| `recol.selection()` | The selected clips |
| `recol.get(id)` | One clip from any clipboard, or `null` |
| `recol.markdown(board?)` | A clipboard as Markdown |

You always get copies, so changing them does nothing. To make a change, use the calls below.

### Changing

| Call | Does |
|---|---|
| `recol.addNote(markdown, { board?, at?, w?, h?, color? })` | Adds a note and returns its id. `at` is `{x, y}` in canvas units. |
| `await recol.addText(text, { board?, at? })` | Adds text. A bare URL becomes a link clip, and an image URL becomes an image. |
| `await recol.addLink(url, { board?, at? })` | Same as `addText`. |
| `recol.update(id, patch)` | Changes `x, y, w, h, z, color, comment, sticky, text, label, group`. `label` renames a clip inside Recol; `group` is any shared string. |
| `recol.remove(ids)` | Deletes clips. The user gets an Undo button. |
| `recol.select(ids)` | Selects clips |
| `recol.openBoard(nameOrId)` | Switches clipboards |
| `recol.newBoard(name, { mood? })` | Makes a clipboard and returns its id |
| `recol.setView('free' \| 'grid' \| 'list')`, `recol.lineUp()` | Changes the view, or lines up clips |
| `recol.copy(text)` | Puts text on the system clipboard |
| `recol.toast(message)` | Shows a short message |
| `await recol.ask(title, value?)` | Asks the user for a line of text. Returns `null` if they cancel. |

### Extending

| Call | Does |
|---|---|
| `recol.command({ id, title, where, run(ctx) })` | Adds a command. `ctx` is `{ clips, board, at? }`. `clips` are the selected clips, and `at` is where the user right-clicked. `run` can be `async`. |
| `recol.on(event, fn)` | Runs `fn` on `'clipAdded'` `(clip, boardId)`, `'clipsRemoved'` `(ids, boardId)`, `'boardChanged'` `({id, name})` or `'selectionChanged'` `(clips)`. |
| `recol.storage.get(key)` / `.set(key, value)` | Saves small JSON values for your plugin. They're stored with the user's clipboards. |
| `recol.plugin` | `{ id, name }` for your plugin |
| `recol.version` | `1` |

### What a clip looks like

```js
{
  id: 'k3j2…', type: 'text' | 'link' | 'image' | 'video' | 'file',
  x, y, w, h, z,               // position and size on the free canvas (canvas units)
  added: 1730000000000,        // when it was added (ms)
  text: '# Markdown…',         // notes
  url: 'https://…',            // links (and images saved from the web)
  name, ext, mime, size,       // files, images, videos
  color: '#6BBFE0', comment: '…', sticky: true
}
```

Notes are Markdown: `# title`, `- bullets`, `**bold**`, `*italic*` and `<u>underline</u>`.

## Examples

Three examples ship with Recol, and they're a good place to start:

- `daily-note/`: one board command that adds a note with today's date.
- `word-count/`: a clip command that reads the selected notes.
- `group-by-kind/`: moves clips into columns with `recol.update`.

## Good plugins are…

- **Fast.** Recol is for in-the-moment organizing, so one click should do the job.
- **Undoable or gentle.** Prefer moving, tagging and adding over deleting. `recol.remove` always offers Undo.
- **Quiet.** Use `toast` to confirm something happened, not to explain.

## Safety

A plugin runs inside Recol with the same access Recol has to your clipboards. Only install plugins
you've read or trust, the same as browser extensions. If a plugin throws an error, its error
message appears under it in **Settings › Plugins**.
