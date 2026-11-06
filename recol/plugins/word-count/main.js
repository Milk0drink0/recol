// A command on clips: right-click selected notes → Word count.
recol.command({
  id: 'count',
  title: 'Word count',
  where: 'clip',                        // shows when you right-click clips
  run(ctx) {
    const notes = ctx.clips.filter(c => c.type === 'text');
    if (!notes.length) return recol.toast('Select a note first');
    const words = notes.reduce((n, c) => n + (c.text.match(/[\p{L}\p{N}’']+/gu) || []).length, 0);
    recol.toast(`${words.toLocaleString()} words in ${notes.length} note${notes.length === 1 ? '' : 's'}`);
  }
});
