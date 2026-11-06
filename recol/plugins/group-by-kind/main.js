// Moves clips around with recol.update(). Positions are in canvas units (x/y = top-left corner).
const ORDER = ['image', 'video', 'file', 'link', 'text'];
const GAP = 24;

recol.command({
  id: 'group',
  title: 'Group by kind',
  where: 'board',
  run() {
    recol.setView('free');
    const clips = recol.clips();
    let x = 200;                         // leave room for the + tile on the left
    for (const type of ORDER) {
      const group = clips.filter(c => c.type === type);
      if (!group.length) continue;
      let y = 24, colW = 0;
      for (const c of group) {
        recol.update(c.id, { x, y });
        y += c.h + GAP; colW = Math.max(colW, c.w);
      }
      x += colW + GAP * 2;
    }
    recol.toast(`Grouped ${clips.length} clips`);
  }
});
