import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui
import "AppModel.js" as AppModel

// Pinned application launcher for the Omarchy bar.
//
// Each pinned entry is one icon. Clicking launches the app, or focuses it when
// it already has a window, so the strip doubles as a switcher. Windows are
// matched to entries by app id / window class, which is also what drives the
// running indicator under each icon.
//
// Pinning is done from the bar itself: the trailing + opens an app picker and
// right-clicking an icon opens its actions. Both borrow the Omarchy menu's
// dmenu mode rather than growing a second picker UI, and both persist through
// `omarchy bar set`, so shell.json stays the single source of truth.
BarWidget {
  id: root
  moduleName: "io.github.joeyvigil.taskbar"

  // AppLibrary owns desktop-entry icon resolution (including the on-disk index
  // that catches icons Qt's cache missed). The bar hands us the shell root.
  readonly property var appLibrary: bar && bar.shell ? bar.shell.appLibrary : null

  readonly property var pinned: AppModel.normalizeApps(root.setting("apps", []))
  readonly property int iconSize: Math.max(8, root.setting("iconSize", 17))
  readonly property int gap: Math.max(0, root.setting("spacing", 2))
  readonly property bool runningIndicator: root.setting("runningIndicator", true) === true
  readonly property bool dimWhenClosed: root.setting("dimWhenClosed", true) === true
  readonly property bool cycleWindows: root.setting("cycleWindows", true) === true
  readonly property bool showAddButton: root.setting("showAddButton", true) === true
  readonly property bool showRunningApps: root.setting("showRunningApps", true) === true

  // Open apps that nothing pinned claims, rendered after the pinned strip and
  // gone again with their last window.
  //
  // Two guards, cheapest first. Every window event reaches here, and the
  // continuous windowtitle ones can change neither which apps are open nor
  // which are claimed, so a fingerprint of the windows is compared before any
  // matching happens. Past that, the list is still only *reassigned* when the
  // set really moved, because handing the Repeater a fresh array tears down
  // and rebuilds every icon.
  property var unpinnedApps: []

  // Deliberately not "": that is the real fingerprint of an empty window list.
  readonly property string noFingerprint: "\u0000"
  property string lastFingerprint: root.noFingerprint

  function refreshUnpinned() {
    if (!root.showRunningApps) {
      if (root.unpinnedApps.length > 0) root.unpinnedApps = []
      return
    }

    var fingerprint = AppModel.windowFingerprint(root.windows,
      AppModel.anyMatchTitle(root.pinned))
    if (fingerprint === root.lastFingerprint) return
    root.lastFingerprint = fingerprint

    var next = AppModel.unpinnedRecords(root.pinned, root.windows)
    if (AppModel.sameKeys(next, root.unpinnedApps)) return
    root.unpinnedApps = next
  }

  // Tracks `windows` rather than `windowSerial`: a shell restart repopulates
  // the toplevel list without Hyprland emitting any event, so a serial-only
  // trigger leaves the strip empty until the user happens to open or close
  // something. `windows` re-evaluates on both.
  onWindowsChanged: root.refreshUnpinned()
  // Editing the pins changes what counts as unclaimed even when not a single
  // window moved, so the fingerprint has to be dropped rather than compared.
  onPinnedChanged: root.forgetFingerprint()
  onShowRunningAppsChanged: root.forgetFingerprint()
  Component.onCompleted: root.refreshUnpinned()

  function forgetFingerprint() {
    root.lastFingerprint = root.noFingerprint
    root.refreshUnpinned()
  }

  // One model for both kinds: the slot delegate, handlePress, launch and focus
  // are all written against a record and neither needs to know the difference.
  readonly property var slots: root.pinned.concat(root.unpinnedApps)

  // With no slots at all and the + turned off the widget would be invisible,
  // so keep a trailing slot in that case purely as an affordance.
  readonly property bool showTrailing: root.showAddButton || root.slots.length === 0

  readonly property int slotSize: root.iconSize + Style.spaceReal(9)

  readonly property string pickerPath: String(Qt.resolvedUrl("bin/taskbar-pick")).replace(/^file:\/\//, "")

  // Hyprland's toplevel objects notify on their own properties, but a list of
  // them does not re-emit when a member's class or title changes. Bumping a
  // serial on every window event gives the descriptor binding something to
  // depend on.
  property int windowSerial: 0
  property int entrySerial: 0

  readonly property string activeAddress: Hyprland.activeToplevel
    ? String(Hyprland.activeToplevel.address || "") : ""

  // Flatten live toplevels into the plain descriptors AppModel matches against.
  function windowDescriptors() {
    var serial = root.windowSerial // binding dependency, see above
    var out = []
    var values = Hyprland.toplevels ? Hyprland.toplevels.values : []
    for (var i = 0; i < values.length; i++) {
      var toplevel = values[i]
      if (!toplevel) continue
      var ipc = toplevel.lastIpcObject || {}
      out.push({
        address: String(toplevel.address || ""),
        appId: toplevel.wayland ? String(toplevel.wayland.appId || "") : "",
        cls: String(ipc["class"] || ""),
        title: String(toplevel.title || ""),
        toplevel: toplevel
      })
    }
    return out
  }

  readonly property var windows: root.windowDescriptors()

  function entryById(desktopId) {
    var serial = root.entrySerial // binding dependency
    var id = String(desktopId || "")
    if (!id) return null
    try {
      var exact = DesktopEntries.byId(id)
      if (exact) return exact
    } catch (e) { }
    // heuristicLookup answers with *some* application rather than nothing, so
    // before the entry index is warm it will hand back an unrelated app and we
    // would paint its icon and name onto this slot. Keep the lookup — it is
    // what resolves "firefox" to org.mozilla.firefox — but only accept a
    // result whose id is actually related to the one asked for.
    try {
      var guess = DesktopEntries.heuristicLookup(id)
      if (guess && root.idsRelated(id, String(guess.id || ""))) return guess
    } catch (e) { }
    return null
  }

  function idsRelated(wanted, found) {
    if (!wanted || !found) return false
    var a = wanted.toLowerCase()
    var b = found.toLowerCase()
    return a === b || a.indexOf(b) !== -1 || b.indexOf(a) !== -1
  }

  function desktopEntry(record) {
    return root.entryById(record ? record.desktopId : "")
  }

  function iconSource(name) {
    if (root.appLibrary) return root.appLibrary.iconSource(name)
    var value = String(name || "")
    if (!value) return ""
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    return Quickshell.iconPath(value, true)
  }

  function labelFor(record) {
    if (record && record.label) return record.label
    var entry = root.desktopEntry(record)
    if (entry && entry.name) return String(entry.name)
    return String(record && record.desktopId || "")
  }

  // ------------------------------------------------------------- launch/focus

  // The shell one-liner that focuses `descriptor` while holding the pointer
  // still. Split out from focusWindow so it can be inspected directly.
  function focusCommand(descriptor) {
    // Quickshell reports the address bare ("55bd…"); Hyprland's dispatcher
    // wants it prefixed. A bad address is only a warning there, exit 0, so
    // getting this wrong fails silently rather than reaching the fallback.
    var hex = String(descriptor.address || "")
    var target = "address:" + (hex.indexOf("0x") === 0 ? hex : "0x" + hex)
    var focusLua = 'hl.dsp.focus({ window = "' + target + '" })'
    return "p=$(hyprctl cursorpos 2>/dev/null | tr -d ' '); "
      // Hyprland's Lua parser rejects the legacy string form and exits 7,
      // which is what selects the fallback on older, non-Lua configs.
      + "hyprctl dispatch " + Util.shellQuote(focusLua) + " >/dev/null 2>&1 || "
      + "hyprctl dispatch focuswindow " + Util.shellQuote(target) + " >/dev/null 2>&1; "
      + 'case "$p" in *,*) hyprctl dispatch '
      + '"hl.dsp.cursor.move({ x = ${p%%,*}, y = ${p#*,} })" >/dev/null 2>&1 ;; esac'
  }

  function focusWindow(descriptor) {
    if (!descriptor) return
    var toplevel = descriptor.toplevel

    // Focusing warps the pointer to the centre of the target window, because
    // Hyprland's cursor:no_warps defaults to false. That drags the pointer off
    // the icon, so a second click lands on the window instead of the taskbar
    // and cycling through an app's windows can never get past the first one.
    //
    // So capture the pointer, focus, and put the pointer back — all in one
    // shell invocation. hyprctl dispatch returns only once the compositor has
    // processed it, so the restore cannot race the warp. Landing the pointer
    // back on the bar does not steal focus: it is a layer surface, and
    // follow_mouse only refocuses when the pointer is over a window.
    if (descriptor.address && root.bar && typeof root.bar.run === "function") {
      root.bar.run(root.focusCommand(descriptor))
      return
    }

    // No way to run commands: fall back to the compositor's own
    // foreign-toplevel activation, which switches workspace but warps.
    if (toplevel && toplevel.wayland && typeof toplevel.wayland.activate === "function") {
      toplevel.wayland.activate()
    }
  }

  function launch(record) {
    if (!record) return
    if (record.exec) {
      if (root.bar) root.bar.run(record.exec)
      return
    }
    if (!record.desktopId) return

    // A running-app record carries the window's own class, which is often but
    // not always a desktop entry id, so resolve it to a real entry before
    // launching. Stored pins are left alone deliberately: entryById falls back
    // to a heuristic lookup that accepts substrings in both directions, and
    // letting that rewrite an id the user chose is the substitution bc1459d
    // was written to close.
    var launchId = record.desktopId
    if (record.unpinned) {
      var entry = root.desktopEntry(record)
      if (entry && entry.id) launchId = String(entry.id)
    }

    if (root.appLibrary) {
      // Goes through AppLibrary so the launch OSD behaves like the menu's.
      root.appLibrary.launch(launchId, root.labelFor(record))
      return
    }
    if (root.bar) {
      root.bar.run("uwsm-app -- gtk-launch " + Util.shellQuote(launchId + ".desktop"))
    }
  }

  function handlePress(record, button) {
    if (button === Qt.MiddleButton) {
      root.launch(record)
      return
    }
    if (button === Qt.RightButton) {
      root.promptActions(record)
      return
    }
    var matched = AppModel.windowsFor(record, root.windows)
    if (matched.length === 0) {
      root.launch(record)
      return
    }
    var index = AppModel.nextWindowIndex(matched, root.activeAddress, root.cycleWindows)
    root.focusWindow(matched[index])
  }

  // ----------------------------------------------------------------- editing

  function layoutEntryIn(config) {
    var layout = config && config.bar ? config.bar.layout : null
    if (!layout) return null
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var list = layout[sections[s]]
      if (!Array.isArray(list)) continue
      for (var i = 0; i < list.length; i++) {
        var entry = list[i]
        if (entry && Util.canonicalWidgetId(String(entry.id || "")) === root.moduleName) return entry
      }
    }
    return null
  }

  // Apply an edit to the pin list.
  //
  // `operation` receives the list as it is *stored* and returns the new list
  // (or null to decline). It deliberately does not receive root.pinned, whose
  // per-instance injected state can be stale on an instance that survived a
  // reload; the read happens at write time instead.
  //
  // Omarchy 4.0.3 capability-scopes third-party plugin shell access
  // (services/PluginShellApi.qml): only kind "bar" plugins may mutate the
  // whole bar config, so for a bar-widget `mutateShellConfig` returns false
  // on every call and every pin save silently did nothing. A widget may,
  // however, write settings to its own bar layout entry through
  // `updateEntryInline`, which every Omarchy 4 host permits.
  function mutateApps(operation) {
    var host = root.bar ? root.bar.shell : null
    if (!host) {
      console.warn("taskbar: no shell facade, refusing to edit pins")
      return
    }

    if (typeof host.updateEntryInline === "function") {
      // root.settings is what the bar host injects per instance and patches
      // after every persist, so it holds the stored list as of the last
      // write. Each edit runs to completion inside one input event, so the
      // read-modify-write never spans two of the user's clicks.
      var stored = AppModel.normalizeApps(
        root.settings && root.settings.apps !== undefined ? root.settings.apps : [])
      var next = operation(stored)
      if (!next) return

      // updateEntryInline replaces the entry wholesale, so carry across every
      // other stored setting (iconSize, spacing, hand-written match/exec/…)
      // — a pin edit must not reset the user's configuration.
      var settings = {}
      for (var key in root.settings) if (key !== "id") settings[key] = root.settings[key]
      settings.apps = AppModel.serialize(next)

      // updateEntryInline returns false when no layout entry answers to this
      // id. Say so — the failure used to be indistinguishable from success.
      if (!host.updateEntryInline(root.moduleName, settings))
        console.warn("taskbar: no layout entry for " + root.moduleName + ", pins not saved")
      return
    }

    // Pre-4.0.3 host: the mutator is ungated there and was the seam this
    // widget was written against. Kept so `omarchy plugin update` can ship
    // this fix to installs still running 4.0.2.
    if (typeof host.mutateShellConfig !== "function") {
      console.warn("taskbar: no shell config mutator, refusing to edit pins")
      return
    }

    host.mutateShellConfig(function(config) {
      var entry = root.layoutEntryIn(config)
      if (!entry) {
        console.warn("taskbar: no layout entry for " + root.moduleName + ", pins not saved")
        return
      }
      var next = operation(AppModel.normalizeApps(entry.apps))
      if (!next) return
      entry.apps = AppModel.serialize(next)
    })
  }

  // Best-effort window-class match for a newly pinned app, so the running
  // indicator works without the user ever learning what a window class is.
  // Returns "" when the id-derived default already covers the app.
  function smartMatch(desktopId) {
    var entry = root.entryById(desktopId)
    if (!entry) return ""

    var startupClass = String(entry.startupClass || "")
    if (startupClass && AppModel.plausibleWindowClass(startupClass)) {
      if (AppModel.defaultCovers(desktopId, startupClass)) return ""
      return "^" + AppModel.escapeRegex(startupClass) + "$"
    }

    var webapp = AppModel.webappPattern(String(entry.execString || ""))
    if (webapp) {
      // The pattern is a regex, so probe it against the class it describes.
      var probe = webapp.replace(/\\/g, "")
      if (AppModel.defaultCovers(desktopId, probe)) return ""
      return webapp
    }
    return ""
  }

  function pinApp(desktopId) {
    var id = String(desktopId || "")
    if (!id) return "no id"

    var record = { desktopId: id }
    var match = root.smartMatch(id)
    if (match) record.match = match

    return root.appendPin(record)
  }

  function unpinApp(desktopId) {
    var id = String(desktopId || "")
    var outcome = "not pinned"
    root.mutateApps(function(current) {
      for (var i = 0; i < current.length; i++) {
        if (current[i].desktopId === id) {
          var next = current.slice()
          next.splice(i, 1)
          outcome = "ok"
          return next
        }
      }
      return null
    })
    return outcome
  }

  // ------------------------------------------------------------------ picker

  function runPicker(kind, context, prompt, options) {
    if (pickerProc.running) return
    pickerProc.kind = kind
    pickerProc.context = context
    var command = Util.shellQuote(root.pickerPath) + " " + Util.shellQuote(prompt)
    for (var i = 0; i < options.length; i++) command += " " + Util.shellQuote(options[i])
    pickerProc.command = ["bash", "-lc", command]
    pickerProc.running = true
  }

  function promptAdd() {
    var rows = []
    if (root.appLibrary) {
      var sorted = root.appLibrary.sortedEntries("")
      for (var i = 0; i < sorted.length; i++) rows.push(sorted[i].entry)
    } else {
      var values = DesktopEntries.applications.values || []
      for (var j = 0; j < values.length; j++) rows.push(values[j])
    }

    var options = []
    for (var k = 0; k < rows.length; k++) {
      var entry = rows[k]
      if (!entry || entry.noDisplay) continue
      var id = String(entry.id || "")
      if (!id || AppModel.hasDesktopId(root.pinned, id)) continue
      options.push("\t" + String(entry.name || id) + "\t" + id)
    }

    if (options.length === 0) return
    root.runPicker("add", "", "Pin app", options)
  }

  function recordForKey(key) {
    var index = AppModel.indexOfKey(root.slots, key)
    return index >= 0 ? root.slots[index] : null
  }

  // Promote a running app into the pinned list. Prefer the resolved desktop
  // entry's own id, so the stored pin is a real entry rather than whatever
  // string the window happened to report.
  function pinRunning(record) {
    if (!record) return "no record"

    var entry = root.desktopEntry(record)
    if (!entry || !entry.id) {
      // No desktop entry answers to this window class. Pin it anyway, keeping
      // the anchored match so the icon still finds its windows; only launching
      // a fresh instance will be unavailable.
      return root.appendPin({ desktopId: record.desktopId, match: record.match })
    }

    var id = String(entry.id)
    var match = root.smartMatch(id)
    // smartMatch infers from the desktop entry, while record.match was built
    // from a window open right now — better evidence when the inference comes
    // up empty. Without this the new pin can fail to claim the very window
    // that produced it, leaving the app with two icons: a dead pin and the
    // live running-app one.
    if (!match && !AppModel.defaultCovers(id, record.desktopId)) match = record.match

    var stored = { desktopId: id }
    if (match) stored.match = match
    return root.appendPin(stored)
  }

  // The single place a record is appended to the stored pin list. Both the +
  // picker and the right-click promotion come through here, so the outcome
  // strings they report over IPC cannot drift apart.
  function appendPin(record) {
    var outcome = "ok"
    root.mutateApps(function(current) {
      if (AppModel.hasDesktopId(current, record.desktopId)) {
        outcome = "already pinned"
        return null
      }
      var next = current.slice()
      next.push(record)
      return next
    })
    return outcome
  }

  function promptActions(record) {
    if (!record) return
    if (record.unpinned) {
      root.runPicker("actions", record.key, root.labelFor(record),
        ["\tNew instance\tlaunch", "\tPin to taskbar\tpin"])
      return
    }

    var index = AppModel.indexOfKey(root.pinned, record.key)
    if (index < 0) return

    var options = ["\tNew instance\tlaunch"]
    if (index > 0) options.push("\t" + (root.vertical ? "Move up" : "Move left") + "\tback")
    if (index < root.pinned.length - 1) options.push("\t" + (root.vertical ? "Move down" : "Move right") + "\tforward")
    options.push("\tUnpin\tunpin")

    root.runPicker("actions", record.key, root.labelFor(record), options)
  }

  // The menu returns "<label>\t<value>"; the value is the field we set.
  function onPicked(kind, context, raw) {
    var text = String(raw || "").trim()
    if (!text) return
    var parts = text.split("\t")
    var value = parts[parts.length - 1]
    if (!value) return

    if (kind === "add") {
      root.pinApp(value)
      return
    }
    if (kind === "actions") root.runAction(context, value)
  }

  function runAction(key, action) {
    // Launching reads nothing back, so the local list is fine for it.
    if (action === "launch") {
      root.launch(root.recordForKey(key))
      return
    }
    if (action === "pin") {
      root.pinRunning(root.recordForKey(key))
      return
    }

    // Everything else edits the list, so it works against stored state.
    root.mutateApps(function(current) {
      var index = AppModel.indexOfKey(current, key)
      if (index < 0) return null
      if (action === "unpin") {
        var next = current.slice()
        next.splice(index, 1)
        return next
      }
      if (action === "back") return AppModel.movedRecords(current, index, -1)
      if (action === "forward") return AppModel.movedRecords(current, index, 1)
      return null
    })
  }

  implicitWidth: layout.implicitWidth
  implicitHeight: layout.implicitHeight

  Process {
    id: pickerProc
    property string kind: ""
    property string context: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onPicked(pickerProc.kind, pickerProc.context, text)
    }
  }

  IpcHandler {
    target: "io.github.joeyvigil.taskbar"

    function pin(desktopId: string): string { return root.pinApp(desktopId) }
    function unpin(desktopId: string): string { return root.unpinApp(desktopId) }
    function list(): string { return JSON.stringify(AppModel.serialize(root.pinned)) }
    function add(): void { root.promptAdd() }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      // openwindow, closewindow, movewindow, windowtitle, activewindow[v2].
      if (String(event.name || "").indexOf("window") !== -1) root.windowSerial++
    }
  }

  Connections {
    target: root.appLibrary
    ignoreUnknownSignals: true
    function onAppsChanged() { root.entrySerial++ }
  }

  GridLayout {
    id: layout
    anchors.fill: parent
    columns: root.vertical ? 1 : Math.max(1, root.slots.length + (root.showTrailing ? 1 : 0))
    columnSpacing: root.vertical ? 0 : root.gap
    rowSpacing: root.vertical ? root.gap : 0

    Repeater {
      model: root.slots

      WidgetButton {
        id: slot
        required property var modelData

        readonly property var matched: AppModel.windowsFor(modelData, root.windows)
        readonly property bool running: matched.length > 0
        readonly property bool focused: {
          if (!running || root.activeAddress === "") return false
          for (var i = 0; i < matched.length; i++) {
            if (matched[i].address === root.activeAddress) return true
          }
          return false
        }

        readonly property var entry: root.desktopEntry(modelData)
        readonly property string iconName: {
          if (modelData.icon) return modelData.icon
          return entry && entry.icon ? String(entry.icon) : String(modelData.desktopId || "")
        }
        readonly property string appLabel: root.labelFor(modelData)

        bar: root.bar
        labelVisible: false
        hasVisualContent: true
        dimmed: root.dimWhenClosed && !running
        tooltipText: appLabel + (matched.length > 1 ? " (" + matched.length + " windows)" : "")
        fixedWidth: root.vertical ? root.barSize : root.slotSize
        fixedHeight: root.vertical ? root.slotSize : root.barSize

        onPressed: function(button) { root.handlePress(slot.modelData, button) }

        Image {
          id: iconImage
          visible: status === Image.Ready
          anchors.centerIn: parent
          // Leave room for the indicator so the icon stays optically centered.
          anchors.verticalCenterOffset: root.runningIndicator && !root.vertical ? -1 : 0
          anchors.horizontalCenterOffset: root.runningIndicator && root.vertical ? 1 : 0
          width: root.iconSize
          height: root.iconSize
          sourceSize.width: root.iconSize * 2
          sourceSize.height: root.iconSize * 2
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          smooth: true
          source: root.iconSource(slot.iconName)
        }

        // Icon lookups fail for entries with no themed icon; a letter tile
        // keeps the slot readable instead of leaving a hole in the bar.
        Text {
          visible: iconImage.status !== Image.Ready
          anchors.centerIn: iconImage
          text: slot.appLabel.substring(0, 1).toUpperCase()
          color: slot.focused ? slot.activeColor : slot.foreground
          font.family: slot.fontFamily
          font.pixelSize: Style.font.bodySmall
          renderType: Text.NativeRendering
        }

        Rectangle {
          visible: root.runningIndicator && slot.running
          readonly property int extent: slot.matched.length > 1 ? 10 : 5
          width: root.vertical ? 2 : extent
          height: root.vertical ? extent : 2
          radius: 1
          color: slot.focused ? slot.activeColor : slot.foreground
          x: root.vertical ? 2 : (slot.width - width) / 2
          y: root.vertical ? (slot.height - height) / 2 : slot.height - height - 3

          Behavior on color {
            ColorAnimation { duration: 160 }
          }
        }
      }
    }

    WidgetButton {
      id: trailing
      visible: root.showTrailing
      bar: root.bar
      text: root.showAddButton ? "\uf067" : "\uf009"
      fontSize: Style.font.bodySmall
      hasVisualContent: root.showTrailing
      pressable: root.showAddButton
      // Sits at full strength while there is nothing pinned, so a fresh widget
      // reads as an invitation rather than as decoration.
      dimmed: root.pinned.length > 0 && !tooltipHovered
      tooltipText: root.showAddButton
        ? "Pin an app"
        : "Taskbar: no apps pinned — add an \"apps\" list to this widget's shell.json entry"
      fixedWidth: root.vertical ? root.barSize : root.slotSize
      fixedHeight: root.vertical ? root.slotSize : root.barSize

      onPressed: function(button) { if (root.showAddButton) root.promptAdd() }
    }
  }
}
