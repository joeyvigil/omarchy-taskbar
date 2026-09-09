# Advanced configuration

Everything here is optional. The `+` button on the bar covers the common cases
without touching a config file — see the [README](../README.md) for the basics
and the settings table.

## Requirements

- Omarchy 4+ (`omarchy-shell`), which provides the bar and the plugin host.
- The built-in `omarchy.menu` plugin, enabled. The `+` and the right-click
  actions are rendered by summoning it in select mode; with it disabled the
  icons still launch and focus, but the editing menus will not open.
- `jq`, used by `bin/taskbar-pick`. It is already a hard dependency of
  `omarchy` itself, so it is present on any Omarchy system.

No other external tools, services, or network access.

## Where settings live

All of it sits inline on the widget's entry in `~/.config/omarchy/shell.json`:

```json
{
  "id": "io.github.joeyvigil.taskbar",
  "apps": ["Alacritty", "chromium", "code"],
  "iconSize": 17,
  "spacing": 2,
  "runningIndicator": true,
  "dimWhenClosed": true,
  "cycleWindows": true,
  "showAddButton": true
}
```

## Running apps that are not pinned

With `showRunningApps` on (the default), any open window no pinned entry claims
gets its own icon after the pinned strip, grouped one icon per application and
removed when its last window closes.

These are derived from what the compositor reports, never from `shell.json`,
and are matched on exactly the app id or window class the window reported —
anchored, unlike the looser word-boundary pattern a hand-written pin gets, so
two unrelated classes can never collapse into one icon. They are ordered
alphabetically, because the compositor reorders its own window list as focus
moves and an icon that shifts under the pointer is worse than no icon.

Right-clicking one offers **Pin to taskbar**, which stores the resolved desktop
entry id, so the pin survives the app closing.

## Pinned entries

The short form is a desktop entry id, without the `.desktop` suffix:

```json
"apps": ["Alacritty", "org.gnome.Nautilus", "code"]
```

The long form takes overrides:

```json
"apps": [
  "Alacritty",
  { "desktopId": "code", "match": "^Code$", "label": "Editor" },
  { "label": "Scratch VM", "icon": "computer", "exec": "uwsm-app -- virt-manager", "match": "virt-manager" }
]
```

| Field | Meaning |
|---|---|
| `desktopId` | Desktop entry id. Supplies the icon, name, and launch command. |
| `match` | Regex matched case-insensitively against window app id and class. Used **raw** — add your own `^…$` or `\b…\b` if you want anchoring. Defaults to a word-boundary match on the desktop id. |
| `exec` | Launch command override. Takes precedence over `desktopId`. |
| `icon` | Icon name or absolute path override. |
| `label` | Tooltip override. |
| `matchTitle` | Also match the regex against window titles. Off by default — titles produce false positives for browsers. |

## Smart matching

The running indicator only lights up if the plugin can tell which windows
belong to a pinned app. When you pin through the `+`, it works this out for you:

- Apps declaring `StartupWMClass` get that class stored as their match.
- Omarchy web apps get a pattern derived from their URL, because Chromium
  reports them with classes like `chrome-discord.com__channels_@me-Default`.
- Apps whose window class already resembles their desktop id get nothing
  stored, keeping the config clean.

So pinning Google Maps from the `+` just works, without you ever finding out
what a window class is.

## When an icon never lights up

Check what the compositor actually reports, then set `match` accordingly:

```bash
hyprctl clients -j | jq -r '.[] | "\(.class)\t\(.title)"'
```

## From the command line

```bash
omarchy-shell io.github.joeyvigil.taskbar list             # current pins, as JSON
omarchy-shell io.github.joeyvigil.taskbar pin obsidian     # pin by desktop entry id
omarchy-shell io.github.joeyvigil.taskbar unpin obsidian   # unpin
omarchy-shell io.github.joeyvigil.taskbar add              # open the pin picker
```

Handy for keybindings, or for adding a "Pin app to taskbar" entry to
`~/.config/omarchy/extensions/omarchy-menu.jsonc`.
