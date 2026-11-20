# Changelog

## 1.3.2

**A realistic spider, 66% less CPU while it hunts**
- Same golden spider, same glow, same behaviour. It just looks real now: jointed legs with dark articulations and fine hairs and spines, a lacquered, finely pitted shell, a velvet abdomen, glassy eyes and soft natural reflections.
- It also does far less work. Measured with the same scenario for both versions (median of 3 runs):
  - Resting: 2.15% → 1.00% CPU (−53%)
  - Walking: 6.1% → 4.8% CPU (−21%)
  - Catching: 20.7% → 7.0% CPU (−66%)
  - Just after catching: 9.3% → 2.2% CPU (−77%)
  - Memory while walking: 206 MB → 111 MB (−46%)
- How: the spider is now drawn only when it actually moves, with no display link running while it rests. Its whole set of legs is a single mesh. A walking spider no longer needs a full-screen drawing surface. The closed Nest no longer runs in the background.

## 1.3.1

**Exclude apps**
- Choose apps SilkNest should never catch from: Settings → Never catch from → Add App…
- Or from the menu bar: "Don't Catch from Safari" (it names whichever app is in front). Click it again to catch from that app again.
- Copies made in an excluded app aren't read at all. Catch Copy (spider menu or its shortcut) and dropping onto the spider still work there, because you ask for them on purpose.
- Only the apps' identifiers are kept, in SilkNest's own settings. Password managers are skipped as before, without being on the list.

## 1.3.0

**A smaller, smarter Nest**
- The Nest now opens as a compact pane in the middle of your screen — about 60% of it — instead of covering everything. Silk is thrown out of the corner nest and the web spreads inside the pane, so you can still see what you were working on.
- It opens on the display your mouse is on, also over full-screen apps and in every Space.
- The search field at the top is a real text field: just start typing. Clicking it (or anywhere on the pane) no longer closes the Nest; only a click outside does.

**A livelier spider**
- A new golden spider, seen from a three-quarter view, with red eyes.
- It hunts: on a copy its body glows red, it catches the item and carries it up its silk to the nest.
- Copy a secret and it turns silver-blue and looks away.
- ⇧⌘Space throws a strand of silk from the spider and the Nest unfolds from it.
- It follows your pointer with its eyes, does a small happy wiggle after a burst of copies, grooms now and then, and dozes on a thread after 10 quiet minutes (the next copy wakes it).
- Every new animation respects System Settings → Accessibility → Display → Reduce Motion. Idle CPU stays where it was.

**Silk Notes do more**
- Right-click a note for Edit, Copy, Pin to the current app (or Make Global), Return to Top, Done ✓ and Delete.
- Reminders: write a time ("call Sam at 4 pm", "at 17:30", "in 20 min") and the note gets a small clock. When it's due, its spider drops down and wiggles the note, with Snooze 10 min and Done. Optionally also as a macOS notification (Settings, off by default).
- Done ✓ puts a note away, with Undo for five seconds.
- Checklists: start lines with `[ ]` and click them to tick them off.
- Notes show up in Nest search (type `note` to see only notes), and any item's card has "Hang as note".

**Much more history**
- SilkNest now remembers **1000** items instead of 30. The web shows one page at a time; scroll, or press Page Down / Page Up, to see older items.
- Search covers all 1000 items — text, links and their domains, file names, the app you copied from, and the text inside screenshots. Pinned items come first, then the newest.
- Type `pin` to see only pinned items.

**Paste Stack**
- Queue several things and paste them in order: press ⌃⌥V after each copy (or ⌘↩ on an item in the Nest, or "Add to Stack" on its card), then every ⌘V pastes the next one. A small counter next to the nest shows how many are queued; "Clear Stack" is in the spider's menu and the menu bar.

**Secrets stay secret**
- API keys and tokens, private keys, card numbers and one-time codes are recognised when you copy them — and also inside screenshots. They are kept in memory only (never saved), shown masked or blurred, and disappear after two minutes unless you pin them. Pasting still pastes the real thing.
- If a screenshot file on your Desktop contains a secret, the spider offers to move it to the Trash (only if you say yes).
- Settings: turn protection off, or never catch secrets at all.

**You decide about screenshots**
- SilkNest no longer turns off macOS's floating screenshot preview on its own. It asks once; if you say no, or change your mind later, your original macOS setting is put back.

**Easier to leave**
- Settings → Uninstall SilkNest… puts the screenshot preview back, removes the login item, optionally deletes your history, notes and settings, and moves SilkNest to the Trash.

**One last Accessibility switch**
- SilkNest now has a permanent signature. macOS sees this version as a new app, so if you use 1-click paste you'll be asked to turn it on **one last time**; after that it stays on through every update.

**Please don't go back to 1.2.2**
- After installing 1.3.0, don't reinstall 1.2.2: it can't read the new history format, and your history would be lost.

**Under the hood**
- History is stored as one encrypted file per item; a new copy no longer rewrites everything. Your existing history is moved over automatically, with a verified backup that is removed once it has opened fine.
- Removing an item, or Clear History, now deletes its files — including the text read from screenshots.
- Lighter on memory: about 70 MB at rest, about 190 MB with the Nest open, about 55 MB with the spider hidden (with 1000 items).

## 1.2.2
- The spider renders into a compact tile, lighter memory and idle loop; history is saved on Quit.
