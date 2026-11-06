// The smallest useful plugin: one command that adds a note.
recol.command({
  id: 'new',
  title: 'New daily note',
  where: 'board',                       // shows when you right-click the canvas and in the R panel
  run(ctx) {
    const today = new Date().toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' });
    recol.addNote(`# ${today}\n- `, { at: ctx.at });
  }
});
