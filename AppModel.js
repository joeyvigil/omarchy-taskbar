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

// An explicit `match` is used as a raw regex, deliberately without the word
// boundaries the derived pattern adds. Auto-filled web app patterns end
// mid-token (chrome-discord.com__channels_@me-Default), where a trailing \b
// would never fire because "_" is a word character.
function matcherFor(record) {
  var pattern = record.match ? String(record.match) : defaultPattern(record.desktopId)
  if (!pattern) return null
  try {
    return new RegExp(pattern, "i")
  } catch (e) {
    // A bad user regex should disable that one button, not break the bar.
    return null
  }
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

// ------------------------------------------------------------------ running
// Windows that are open but do not belong to any pinned entry are collected
// into transient "running" slots (one icon per desktop entry, never persisted).

function entryTier(entry, token) {
  if (!entry || !token) return 0
  var t = String(token).toLowerCase()
  var id = String(entry.id || "")
  var idStripped = id.length > 8 && id.slice(-8).toLowerCase() === ".desktop"
    ? id.slice(0, -8) : id
  var startup = String(entry.startupClass || "")
  var exec = String(entry.execString || "").trim().split(/\s+/)[0].split("/").pop()
  if (t === id.toLowerCase() || t === idStripped.toLowerCase()) return 3
  if (startup && plausibleWindowClass(startup) && t === startup.toLowerCase()) return 3
  if (exec && exec !== "env" && exec !== "uwsm-app" && exec !== "sh"
      && t === exec.toLowerCase()) return 3
  if (defaultCovers(id, token)) return 2
  var web = webappPattern(String(entry.execString || ""))
  if (web) { try { if (new RegExp(web, "i").test(token)) return 2 } catch (e) {} }
  if (t === String(entry.name || "").toLowerCase()) return 1
  return 0
}

function entryForToken(entries, token) {
  if (!token) return null
  var best = null, bestTier = 0
  var all = toArray(entries)
  for (var i = 0; i < all.length; i++) {
    var tier = entryTier(all[i], token)
    if (tier > bestTier) { bestTier = tier; best = all[i] }
  }
  return best
}

// Transient slots: windows not claimed by any pinned record, grouped by the
// desktop entry they resolve to. Returns an array of records shaped so the
// existing delegate (icon, running indicator, focus highlight, click to
// focus/cycle) works unchanged. Never persisted.
function runningGroups(records, windows, entries) {
  var all = toArray(windows)
  var claimed = {}
  var recs = toArray(records)
  for (var i = 0; i < recs.length; i++) {
    var ws = windowsFor(recs[i], all)
    for (var k = 0; k < ws.length; k++) {
      if (ws[k] && ws[k].address) claimed[ws[k].address] = true
    }
  }
  var buckets = [], byKey = {}
  function tokensOf(w) {
    var o = []
    if (w.cls) o.push(String(w.cls))
    if (w.appId && w.appId !== w.cls) o.push(String(w.appId))
    return o
  }
  for (var j = 0; j < all.length; j++) {
    var win = all[j]
    if (!win || (win.address && claimed[win.address])) continue
    var tokens = tokensOf(win)
    var entry = null, tier = 0
    for (var t = 0; t < tokens.length; t++) {
      var e = entryForToken(entries, tokens[t])
      var tr = e ? entryTier(e, tokens[t]) : 0
      if (tr > tier) { tier = tr; entry = e }
    }
    var key = entry ? String(entry.id || "") : ("anon:" + (tokens[0] || win.address))
    var b = byKey[key]
    if (!b) {
      b = {
        key: key,
        desktopId: entry ? String(entry.id || "") : "",
        label: entry ? String(entry.name || entry.id) : (tokens[0] || "App"),
        icon: entry ? String(entry.icon || "") : (tokens[0] || ""),
        tokens: {},
        temp: true
      }
      byKey[key] = b
      buckets.push(b)
    }
    for (var u = 0; u < tokens.length; u++) b.tokens[tokens[u]] = true
  }
  var out = []
  for (var g = 0; g < buckets.length; g++) {
    var b = buckets[g]
    var list = Object.keys(b.tokens)
    if (!list.length) continue
    var alts = []
    for (var a = 0; a < list.length; a++) alts.push(escapeRegex(list[a]))
    out.push({
      desktopId: b.desktopId,
      icon: b.icon,
      label: b.label,
      match: "^(" + alts.join("|") + ")$",
      key: b.key,
      temp: true
    })
  }
  return out
}
