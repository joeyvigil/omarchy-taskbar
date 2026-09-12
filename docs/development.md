# Development notes

```
manifest.json      plugin declaration and setting schema
BarWidget.qml      the widget the bar mounts
AppModel.js        entry normalization, window matching, list editing
bin/taskbar-pick   shows a list in the Omarchy menu, prints the choice
```

Two things worth knowing before changing this code:

**Settings arrays are not `Array`s.** Values from `shell.json` round-trip
through a QML `property var`, which stores JS arrays as `QVariantList`. What
comes back is array-*like* but fails `Array.isArray`, so `AppModel.toArray`
duck-types on `length` instead. Trusting `Array.isArray` silently drops every
pinned app at cold start while still working under hot-reload, which makes it a
nasty one to catch — always test with `omarchy restart shell`, not just a save.

**Pins are persisted in-process.** Omarchy 4.0.3 capability-scopes plugin
shell access: only kind "bar" plugins may call `mutateShellConfig`, so the
widget persists through `updateEntryInline` — the seam a host permits for
writing its own bar layout entry — and falls back to the ungated mutator on
hosts where `updateEntryInline` is absent. Both write the entry wholesale, so
edits merge the currently stored settings rather than building them from
scratch. The tidier `omarchy bar set <id> apps '[…]' --json` still cannot be
used: it forwards through `qs ipc call`, which splits every argument on
commas, so any array past one element arrives as extra positional arguments
and the call is rejected.

Files under `~/.config/omarchy/plugins/` hot-reload on save. If you develop from
a checkout elsewhere and symlink it in, `inotify` won't see through the symlink
— reload by hand with `omarchy-shell shell rescanPlugins`, and restart the
shell outright when you touch anything settings-related.
