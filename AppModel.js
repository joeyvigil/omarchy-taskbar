.pragma library

// Pure helpers for the taskbar widget: turning shell.json entries into pinned
// app records, and deciding which open windows belong to which record.
//
// Deliberately free of QML globals so it can stay a `.pragma library` shared
// across every bar instance. The widget hands in plain window descriptors
// ({ address, appId, cls, title }) rather than live Hyprland objects.

// Settings arriving from shell.json have round-tripped through a QML
// `property var`, which stores JS arrays as QVariantList. Reading one back
// yields an array-*like* sequence wrapper that fails Array.isArray, so guard
// on duck-typed length instead and hand back a genuine array.
function toArray(value) {
  if (value === null || value === undefined) return []
  if (Array.isArray(value)) return value
  if (typeof value === "string") return []
  if (typeof value.length !== "number") return []
  var out = []
  for (var i = 0; i < value.length; i++) out.push(value[i])
  return out
}

function escapeRegex(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

// "org.telegram.desktop" -> "desktop" is useless as a match, but for ids like
// "com.mitchellh.ghostty" the trailing segment is what Hyprland reports. Keep
// both and let the matcher try either.
function idVariants(desktopId) {
  var id = String(desktopId || "")
  if (!id) return []
  var variants = [id]
  var parts = id.split(".")
  var tail = parts[parts.length - 1]
  if (parts.length > 1 && tail.length > 2 && tail !== "desktop") variants.push(tail)
  return variants
}

// The derived pattern for an entry with no explicit `match`: an alternation
// over the desktop id variants, anchored on word boundaries the same way
// omarchy-launch-or-focus does, so "code" does not match "codes".
function defaultPattern(desktopId) {
  var variants = idVariants(desktopId)
  if (variants.length === 0) return ""
  var escaped = []
  for (var i = 0; i < variants.length; i++) escaped.push(escapeRegex(variants[i]))
  return "\\b(" + escaped.join("|") + ")\\b"
}

// The pattern for one exact window class, as reported. Deliberately tighter
// than defaultPattern: that one is loose on purpose, which is right for a pin
// the user chose but would let two unrelated classes share an icon here.
function exactPattern(value) {
  return "^" + escapeRegex(value) + "$"
}

// An explicit `match` is used as a raw regex, deliberately without the word
// boundaries the derived pattern adds. Auto-filled web app patterns end
// mid-token (chrome-discord.com__channels_@me-Default), where a trailing \b
// would never fire because "_" is a word character.
// Compiled matchers live on the .pragma library scope, which lasts for the
// process and is shared by every bar instance. Keyed on the pattern text, so
// it never needs invalidating — the same pattern always compiles to the same
// matcher. Safe to share one RegExp: there is no /g or /y flag, so .test()
// never touches lastIndex.
var compiledMatchers = {}

function matcherFor(record) {
  var pattern = record.match ? String(record.match) : defaultPattern(record.desktopId)
  if (!pattern) return null
  if (pattern in compiledMatchers) return compiledMatchers[pattern]

  var compiled = null
  try {
    compiled = new RegExp(pattern, "i")
  } catch (e) {
    // A bad user regex should disable that one button, not break the bar.
    compiled = null
  }
  compiledMatchers[pattern] = compiled
  return compiled
}

// True when the derived pattern already covers this window class, meaning the
// entry needs no explicit match stored.
function defaultCovers(desktopId, cls) {
  var pattern = defaultPattern(desktopId)
  if (!pattern || !cls) return false
  try {
    return new RegExp(pattern, "i").test(String(cls))
  } catch (e) {
    return false
  }
}

// Omarchy web apps run through Chromium's --app mode, which builds the window
// class as chrome-<host>__<first-path-segment>...-Default. Host alone would
// collide across apps on one domain (Google Maps vs Google Photos), so keep
// the first path segment too.
function webappPattern(execString) {
  var exec = String(execString || "")
  if (exec.indexOf("omarchy-launch-webapp") === -1) return ""
  var found = /https?:\/\/([^\s"']+)/.exec(exec)
  if (!found) return ""
  var target = found[1].replace(/\/+$/, "")
  var slash = target.indexOf("/")
  if (slash === -1) return escapeRegex(target)
  var host = target.substring(0, slash)
  var segment = target.substring(slash + 1).split("/")[0]
  if (!segment) return escapeRegex(host)
  return escapeRegex(host + "__" + segment)
}

// Accepts either a bare string ("chromium") or a full object. Everything the
// widget reads later is present on the returned record, so the QML side never
// has to re-check for undefined.
function normalizeApp(entry, index) {
  var record = null

  if (typeof entry === "string") {
    record = { desktopId: entry }
  } else if (entry && typeof entry === "object") {
    record = {
      desktopId: String(entry.desktopId || entry.id || ""),
      match: String(entry.match || ""),
      exec: String(entry.exec || ""),
      icon: String(entry.icon || ""),
      label: String(entry.label || entry.tooltip || ""),
      matchTitle: entry.matchTitle === true
    }
  }

  if (!record) return null

  record.desktopId = String(record.desktopId || "")
  record.match = String(record.match || "")
  record.exec = String(record.exec || "")
  record.icon = String(record.icon || "")
  record.label = String(record.label || "")
  record.matchTitle = record.matchTitle === true

  // Nothing to launch and nothing to match against — drop it rather than
  // rendering a dead button.
  if (!record.desktopId && !record.exec && !record.match) return null

  record.key = record.desktopId || record.match || record.exec || ("app-" + index)
  return record
}

function normalizeApps(list) {
  var entries = toArray(list)
  var out = []
  for (var i = 0; i < entries.length; i++) {
    var record = normalizeApp(entries[i], i)
    if (record) out.push(record)
  }
  return out
}

function windowMatches(record, matcher, window) {
  if (!matcher || !window) return false
  if (matcher.test(String(window.appId || ""))) return true
  if (matcher.test(String(window.cls || ""))) return true
  if (record.matchTitle && matcher.test(String(window.title || ""))) return true
  return false
}

// Returns the subset of `windows` belonging to this record, in the order the
// compositor reported them so cycling is stable between clicks.
function windowsFor(record, windows) {
  var matcher = matcherFor(record)
  if (!matcher) return []
  var all = toArray(windows)
  var out = []
  for (var i = 0; i < all.length; i++) {
    if (windowMatches(record, matcher, all[i])) out.push(all[i])
  }
  return out
}

// Windows that no pinned record claims, grouped into one synthetic record per
// application. The widget renders these after the pinned strip, so an app you
// never pinned still gets an icon while it is open and loses it when its last
// window closes — the way a Windows or macOS taskbar behaves.
function unpinnedRecords(pinned, windows) {
  var all = toArray(windows)
  if (!all.length) return []

  // Resolve each pinned matcher once rather than per window.
  var pins = toArray(pinned)
  var claims = []
  for (var p = 0; p < pins.length; p++) {
    claims.push({ record: pins[p], matcher: matcherFor(pins[p]) })
  }

  // Lowered identity -> the identity as the window actually reported it. The
  // one map both de-duplicates and orders: its keys are already lowercased, so
  // they sort without a comparator.
  var byKey = {}
  for (var i = 0; i < all.length; i++) {
    var win = all[i]
    var claimed = false
    for (var c = 0; c < claims.length; c++) {
      if (windowMatches(claims[c].record, claims[c].matcher, win)) {
        claimed = true
        break
      }
    }
    if (claimed) continue

    // appId is the Wayland identity a desktop entry is keyed on; cls is the
    // fallback for clients that report only a class.
    var identity = String(win.appId || win.cls || "")
    if (!identity) continue
    var key = identity.toLowerCase()
    if (!(key in byKey)) byKey[key] = identity
  }

  // Sorted, because the compositor reorders its toplevel list as focus moves
  // and an icon that changes place under the pointer is worse than no icon.
  var keys = Object.keys(byKey).sort()
  var out = []
  for (var k = 0; k < keys.length; k++) {
    var id = byKey[keys[k]]
    // Built through normalizeApp so a synthetic record has exactly the shape a
    // stored one does and the widget never has to ask which kind it is holding.
    var record = normalizeApp({ desktopId: id, match: exactPattern(id) }, k)
    if (!record) continue
    // Not from shell.json: never written back, and its right-click menu offers
    // pinning rather than unpinning and reordering. serialize() whitelists
    // fields, so neither of these can reach the config even by accident.
    record.unpinned = true
    // Namespaced so it cannot collide with a stored pin for the same id.
    record.key = "unpinned:" + id
    out.push(record)
  }
  return out
}

// True when any record matches on window titles. Titles change constantly, so
// the widget only has to fold them into its change check when a record asked.
function anyMatchTitle(records) {
  var all = toArray(records)
  for (var i = 0; i < all.length; i++) {
    if (all[i] && all[i].matchTitle) return true
  }
  return false
}

// A cheap fingerprint of everything the unpinned set can depend on. Sorted, so
// the compositor reordering its own list does not read as a change, and title
// text is folded in only when some record matches on titles. Computing this
// first is what keeps the continuous windowtitle events off the matcher pass.
function windowFingerprint(windows, includeTitles) {
  var all = toArray(windows)
  var parts = []
  for (var i = 0; i < all.length; i++) {
    var win = all[i]
    var part = String(win.appId || win.cls || "")
    if (includeTitles) part += "\u0001" + String(win.title || "")
    parts.push(part)
  }
  return parts.sort().join("\u0002")
}

// Whether two record lists name the same apps in the same order. Handing the
// Repeater a fresh array tears down and rebuilds every icon, so the widget
// only reassigns when this says something actually moved.
function sameKeys(a, b) {
  var left = toArray(a)
  var right = toArray(b)
  if (left.length !== right.length) return false
  for (var i = 0; i < left.length; i++) {
    if (left[i].key !== right[i].key) return false
  }
  return true
}

// Index of the window to focus. Without cycling that is always the first
// match; with cycling, a click while one of the app's windows is focused
// advances to the next one and wraps.
function nextWindowIndex(windows, activeAddress, cycle) {
  if (!windows.length) return -1
  if (!cycle || !activeAddress) return 0
  for (var i = 0; i < windows.length; i++) {
    if (windows[i].address === activeAddress) return (i + 1) % windows.length
  }
  return 0
}

// StartupWMClass is only worth trusting when it looks like a real class.
// Arch's chromium.desktop ships `StartupWMClass=@@startup_wm_class`, an
// unsubstituted packaging template; storing that as a match produces an entry
// whose indicator can never fire. Anything that is not a plain class token
// falls back to the desktop-id pattern, which is usually right anyway.
function plausibleWindowClass(value) {
  var text = String(value || "")
  if (!text || text.length > 128) return false
  return /^[A-Za-z0-9][A-Za-z0-9._+-]*$/.test(text)
}

// ------------------------------------------------------------------ editing

function indexOfKey(records, key) {
  var all = toArray(records)
  for (var i = 0; i < all.length; i++) {
    if (all[i] && all[i].key === key) return i
  }
  return -1
}

function hasDesktopId(records, desktopId) {
  var all = toArray(records)
  for (var i = 0; i < all.length; i++) {
    if (all[i] && all[i].desktopId === desktopId) return true
  }
  return false
}

// Move the entry at `index` by `delta` slots, clamped. Returns a new array.
function movedRecords(records, index, delta) {
  var all = toArray(records).slice()
  var target = index + delta
  if (index < 0 || index >= all.length) return all
  if (target < 0 || target >= all.length) return all
  var moved = all.splice(index, 1)[0]
  all.splice(target, 0, moved)
  return all
}

// Back to the shape shell.json wants. Entries carrying nothing but a desktop
// id collapse to the bare string form, so hand-written configs stay readable
// after the UI has edited them.
function serialize(records) {
  var all = toArray(records)
  var out = []
  for (var i = 0; i < all.length; i++) {
    var record = all[i]
    if (!record) continue
    var object = {}
    var decorated = false
    if (record.desktopId) object.desktopId = record.desktopId
    if (record.match) { object.match = record.match; decorated = true }
    if (record.exec) { object.exec = record.exec; decorated = true }
    if (record.icon) { object.icon = record.icon; decorated = true }
    if (record.label) { object.label = record.label; decorated = true }
    if (record.matchTitle) { object.matchTitle = true; decorated = true }
    out.push(!decorated && record.desktopId ? record.desktopId : object)
  }
  return out
}
