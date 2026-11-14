import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  property string page: "chooseType"
  property string returnPageAfterTarget: "chooseType"
  property string appSearch: ""
  property string shortcutSearch: ""
  property string statusMessage: ""
  property bool statusIsError: false
  property bool loading: false
  property int appsRevision: 0
  property string pendingHelperTask: ""
  property string helperOutput: ""
  property string helperStderr: ""
  property var helperQueue: []
  property var customEntries: []
  property var systemEntries: []
  property var selectedEntry: null
  property string editingId: ""
  property string originalKeys: ""
  property string originalDescription: ""
  property string currentKeys: ""
  property string capturedKeys: ""
  property string manualShortcutText: ""
  property bool manualEntryActive: false
  property bool captureModeActive: false
  property bool captureModePending: false
  property string selectedDesktopId: ""
  property string selectedAppName: ""
  property string selectedSystemAction: ""
  property string removeTargetId: ""
  property var pendingConflict: null
  property int typeChoiceIndex: 0
  property int appSelectedIndex: 0
  property bool appCursorActive: false
  property int actionSelectedIndex: 0
  property int editSelectedIndex: 0
  property bool editCursorActive: false
  property int confirmFocusIndex: 0
  property int savedFocusIndex: 0

  readonly property string fontFamily: Style.font.menuFamily
  readonly property var appLibrary: root.shell ? root.shell.appLibrary : null
  readonly property string customConfigPath: {
    var base = Quickshell.env("XDG_CONFIG_HOME")
    if (!base) base = Quickshell.env("HOME") + "/.config"
    return base + "/hypr/omarchy-keybindings-custom.lua"
  }
  readonly property var systemActions: [
    { id: "screenshot", icon: "", labelKey: "actionScreenshot", detailKey: "actionScreenshotDetail" },
    { id: "lock", icon: "", labelKey: "actionLock", detailKey: "actionLockDetail" },
    { id: "workspace-next", icon: "󰁔", labelKey: "actionNextWorkspace", detailKey: "actionNextWorkspaceDetail" },
    { id: "workspace-previous", icon: "󰁍", labelKey: "actionPreviousWorkspace", detailKey: "actionPreviousWorkspaceDetail" },
    { id: "volume-up", icon: "", labelKey: "actionVolumeUp", detailKey: "actionVolumeUpDetail" },
    { id: "volume-down", icon: "", labelKey: "actionVolumeDown", detailKey: "actionVolumeDownDetail" },
    { id: "volume-mute", icon: "󰖁", labelKey: "actionMute", detailKey: "actionMuteDetail" }
  ]
  readonly property string pluginDir: root.manifest && root.manifest.__sourceDir
    ? String(root.manifest.__sourceDir)
    : Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.splashymorningstar.keybindings"
  readonly property var apps: {
    root.appsRevision
    return root.appLibrary ? root.appLibrary.sortedEntries(root.appSearch) : []
  }
  readonly property var shortcutEntries: {
    var entries = []
    var query = root.shortcutSearch.trim().toLocaleLowerCase()
    var custom = root.customEntries || []
    var system = root.systemEntries || []
    for (var i = 0; i < custom.length; i++) {
      var own = custom[i]
      var customRow = {
        id: own.id,
        name: own.name,
        keys: own.keys,
        kind: own.kind || "application",
        actionId: own.actionId || "",
        desktopId: own.desktopId,
        originalKeys: own.originalKeys || "",
        originalDescription: own.originalDescription || "",
        source: "custom"
      }
      if (!query || (customRow.name + " " + customRow.keys + " " + customRow.originalDescription).toLocaleLowerCase().indexOf(query) >= 0)
        entries.push(customRow)
    }
    for (var j = 0; j < system.length; j++) {
      var systemRow = {
        id: "",
        name: system[j].description,
        keys: system[j].keys,
        desktopId: "",
        originalKeys: system[j].keys,
        originalDescription: system[j].description,
        source: "system"
      }
      if (!query || (systemRow.name + " " + systemRow.keys).toLocaleLowerCase().indexOf(query) >= 0)
        entries.push(systemRow)
    }
    return entries
  }

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) {}
    root.opened = true
    root.statusMessage = ""
    if (payload.mode === "edit") root.startEdit()
    else root.startCreate()
  }

  function close() {
    root.stopSafeCapture()
    root.opened = false
  }

  function dismiss() {
    root.close()
    if (root.shell && root.manifest && root.shell.hide)
      root.shell.hide(root.manifest.id)
  }

  function runHelper(args, task) {
    if (helperProcess.running) {
      root.helperQueue = root.helperQueue.concat([{ args: args.slice(), task: task }])
      if (task === "list-custom" || task === "list-system") root.loading = true
      return
    }
    root.startHelper(args, task)
  }

  function hasQueuedHelper(task) {
    for (var i = 0; i < root.helperQueue.length; i++)
      if (root.helperQueue[i].task === task) return true
    return false
  }

  function removeQueuedHelpers(task) {
    root.helperQueue = root.helperQueue.filter(function(item) { return item.task !== task })
  }

  function startHelper(args, task) {
    root.pendingHelperTask = task
    root.helperOutput = ""
    root.helperStderr = ""
    root.loading = task === "list-custom" || task === "list-system"
    helperProcess.command = ["python3", root.pluginDir + "/manager.py"].concat(args)
    helperProcess.running = true
  }

  function startQueuedHelper() {
    if (helperProcess.running || root.helperQueue.length === 0) return
    var next = root.helperQueue[0]
    root.helperQueue = root.helperQueue.slice(1)
    root.startHelper(next.args, next.task)
  }

  function loadShortcuts() {
    root.runHelper(["list-custom"], "list-custom")
  }

  function refreshEditList() {
    root.statusMessage = ""
    root.page = "edit"
    root.shortcutSearch = ""
    root.loadShortcuts()
  }

  function handleHelperExit(exitCode) {
    var task = root.pendingHelperTask
    root.pendingHelperTask = ""
    root.loading = false
    Qt.callLater(function() { root.startQueuedHelper() })

    var result = null
    try { result = JSON.parse(root.helperOutput || "") } catch (e) {}

    if (task === "capture-start") {
      root.captureModePending = false
      if (result && result.ok) {
        if (!root.opened || root.page !== "capture") {
          root.runHelper(["capture-stop"], "capture-stop")
          return
        }
        root.captureModeActive = true
        root.statusIsError = false
        root.statusMessage = ""
        Qt.callLater(function() { interactionInput.forceActiveFocus() })
      } else {
        root.captureModeActive = false
        root.statusIsError = true
        root.statusMessage = strings.t("captureModeFailed")
          .arg((result && result.message) || root.helperStderr || "Unknown error")
        Qt.callLater(function() { manualShortcutInput.forceActiveFocus() })
      }
      return
    }
    if (task === "capture-stop") {
      root.captureModePending = root.hasQueuedHelper("capture-start")
      root.captureModeActive = false
      if (result && !result.ok && root.opened) {
        root.statusIsError = true
        root.statusMessage = strings.t("captureModeRestoreFailed").arg(result.message || "")
      }
      return
    }

    if (!result) {
      if (task === "capture-start") {
        root.captureModePending = false
        root.statusIsError = true
        root.statusMessage = strings.t("captureModeFailed")
          .arg(root.helperStderr || "No response from the shortcut manager.")
        Qt.callLater(function() { manualShortcutInput.forceActiveFocus() })
        return
      }
      if (task === "capture-stop") {
        root.captureModeActive = false
        root.captureModePending = root.hasQueuedHelper("capture-start")
        if (root.opened) {
          root.statusIsError = true
          root.statusMessage = strings.t("captureModeRestoreFailed")
            .arg(root.helperStderr || "No response from the shortcut manager.")
        }
        return
      }
      if (task) {
        root.statusIsError = true
        root.statusMessage = strings.t("saveFailed").arg(root.helperStderr || "No response from the shortcut manager.")
      }
      return
    }

    if (!result.ok) {
      root.statusIsError = true
      if (result.kind === "conflict" && result.conflict && result.conflict.replaceable) {
        root.pendingConflict = result.conflict
        root.statusMessage = ""
        overwriteDialog.selectedIndex = 1
        overwriteDialog.opened = true
        Qt.callLater(function() { interactionInput.forceActiveFocus() })
      } else if (result.kind === "conflict") {
        root.pendingConflict = null
        root.statusMessage = strings.t("conflictReserved")
          .arg((result.conflict && result.conflict.description) || result.message || "")
      } else {
        root.pendingConflict = null
        root.statusMessage = strings.t("saveFailed").arg(result.message || root.helperStderr || "Unknown error")
      }
      return
    }

    if (task === "list-custom") {
      root.customEntries = Array.isArray(result.entries) ? result.entries : []
      Qt.callLater(function() { root.runHelper(["list-system"], "list-system") })
      return
    }
    if (task === "list-system") {
      root.systemEntries = Array.isArray(result.entries) ? result.entries : []
      return
    }
    if (task === "save-app" || task === "save-action") {
      root.statusIsError = false
      root.statusMessage = ""
      root.pendingConflict = null
      root.selectedEntry = null
      root.page = "saved"
      root.savedFocusIndex = 0
      Qt.callLater(function() { createAnotherButton.forceActiveFocus() })
      return
    }
    if (task === "remove") {
      root.statusIsError = false
      root.statusMessage = strings.t("removed")
      root.removeTargetId = ""
      root.page = "edit"
      root.editCursorActive = false
      Qt.callLater(function() {
        root.loadShortcuts()
        shortcutSearchField.forceActiveFocus()
      })
    }
  }

  function startCreate() {
    root.statusMessage = ""
    root.statusIsError = false
    root.returnPageAfterTarget = "chooseType"
    root.editingId = ""
    root.originalKeys = ""
    root.originalDescription = ""
    root.currentKeys = ""
    root.capturedKeys = ""
    root.manualShortcutText = ""
    root.manualEntryActive = false
    root.selectedEntry = null
    root.selectedDesktopId = ""
    root.selectedAppName = ""
    root.selectedSystemAction = ""
    root.appSearch = ""
    root.typeChoiceIndex = 0
    root.appCursorActive = false
    root.editCursorActive = false
    root.page = "chooseType"
    Qt.callLater(function() { createApplicationButton.forceActiveFocus() })
  }

  function startApplicationCreate() {
    root.selectedSystemAction = ""
    root.selectedDesktopId = ""
    root.selectedAppName = ""
    root.appSearch = ""
    root.appSelectedIndex = 0
    root.appCursorActive = false
    root.page = "apps"
    Qt.callLater(function() { applicationSearch.forceActiveFocus() })
  }

  function startActionCreate() {
    root.selectedSystemAction = ""
    root.selectedDesktopId = ""
    root.selectedAppName = ""
    root.actionSelectedIndex = 0
    root.page = "actions"
    Qt.callLater(function() { root.focusSystemAction(0) })
  }

  function openCustomConfig() {
    root.dismiss()
    Qt.callLater(function() {
      Quickshell.execDetached(["omarchy-launch-tui", "nvim", root.customConfigPath])
    })
  }

  function systemActionLabel(actionId) {
    for (var i = 0; i < root.systemActions.length; i++) {
      if (root.systemActions[i].id === actionId)
        return strings.t(root.systemActions[i].labelKey)
    }
    return ""
  }

  function selectSystemAction(actionId) {
    root.selectedSystemAction = String(actionId || "")
    root.selectedAppName = root.systemActionLabel(root.selectedSystemAction)
    root.selectedDesktopId = ""
    root.beginCapture()
  }

  function keepSelectedSystemAction() {
    if (!root.selectedSystemAction) return
    root.selectedAppName = root.systemActionLabel(root.selectedSystemAction)
    root.beginCapture()
  }

  function moveTypeSelection(delta) {
    root.typeChoiceIndex = (root.typeChoiceIndex + delta + 3) % 3
    Qt.callLater(function() {
      if (root.typeChoiceIndex === 0) createApplicationButton.forceActiveFocus()
      else if (root.typeChoiceIndex === 1) systemActionButton.forceActiveFocus()
      else customCommandButton.forceActiveFocus()
    })
  }

  function moveAppSelection(delta) {
    var count = root.apps.length
    if (count === 0) return
    if (!root.appCursorActive) {
      root.appCursorActive = true
      if (root.appSelectedIndex < 0 || root.appSelectedIndex >= count)
        root.appSelectedIndex = delta < 0 ? count - 1 : 0
    } else {
      var next = root.appSelectedIndex + delta
      if (next < 0) {
        root.appCursorActive = false
        applicationSearch.forceActiveFocus()
        return
      }
      root.appSelectedIndex = Math.min(count - 1, next)
    }
    appList.positionViewAtIndex(root.appSelectedIndex, ListView.Contain)
    Qt.callLater(function() {
      var row = appList.itemAtIndex(root.appSelectedIndex)
      if (row) row.forceActiveFocus()
    })
  }

  function selectCurrentApplication() {
    if (root.appSelectedIndex < 0 || root.appSelectedIndex >= root.apps.length) return
    var entry = root.apps[root.appSelectedIndex]
    if (entry && entry.entry) entry = entry.entry
    root.selectApplication(entry)
  }

  function moveActionSelection(delta) {
    if (root.systemActions.length === 0) return
    var next = Math.max(0, Math.min(root.systemActions.length - 1, root.actionSelectedIndex + delta))
    root.focusSystemAction(next)
  }

  function focusSystemAction(index) {
    if (root.systemActions.length === 0) return
    root.actionSelectedIndex = Math.max(0, Math.min(root.systemActions.length - 1, index))
    systemActionList.positionViewAtIndex(root.actionSelectedIndex, ListView.Contain)
    Qt.callLater(function() {
      var row = systemActionList.itemAtIndex(root.actionSelectedIndex)
      if (row && row.keyboardButton) row.keyboardButton.forceActiveFocus()
    })
  }

  function moveEditSelection(delta) {
    var count = root.shortcutEntries.length
    if (count === 0) return
    if (!root.editCursorActive) {
      root.editCursorActive = true
      if (root.editSelectedIndex < 0 || root.editSelectedIndex >= count)
        root.editSelectedIndex = delta < 0 ? count - 1 : 0
    } else {
      var next = root.editSelectedIndex + delta
      if (next < 0) {
        root.editCursorActive = false
        shortcutSearchField.forceActiveFocus()
        return
      }
      root.editSelectedIndex = Math.min(count - 1, next)
    }
    shortcutList.positionViewAtIndex(root.editSelectedIndex, ListView.Contain)
    Qt.callLater(function() {
      var row = shortcutList.itemAtIndex(root.editSelectedIndex)
      if (row && row.focusButton) row.focusButton.forceActiveFocus()
    })
  }

  function selectCurrentShortcut() {
    if (root.editSelectedIndex < 0 || root.editSelectedIndex >= root.shortcutEntries.length) return
    root.editEntry(root.shortcutEntries[root.editSelectedIndex])
  }

  function moveConfirmFocus(delta) {
    root.confirmFocusIndex = (root.confirmFocusIndex + delta + 2) % 2
    Qt.callLater(function() {
      if (root.confirmFocusIndex === 0) saveShortcutButton.forceActiveFocus()
      else confirmBackButton.forceActiveFocus()
    })
  }

  function moveSavedFocus(delta) {
    root.savedFocusIndex = (root.savedFocusIndex + delta + 2) % 2
    Qt.callLater(function() {
      if (root.savedFocusIndex === 0) createAnotherButton.forceActiveFocus()
      else closeSavedButton.forceActiveFocus()
    })
  }

  function handleButtonNavigation(event, pageName) {
    if (event.key === Qt.Key_Escape) {
      root.cancelFlow()
      event.accepted = true
      return true
    }
    var delta = event.key === Qt.Key_Up || event.key === Qt.Key_Left
      ? -1
      : event.key === Qt.Key_Down || event.key === Qt.Key_Right ? 1 : 0
    if (delta === 0) return false
    if (pageName === "chooseType") root.moveTypeSelection(delta)
    else if (pageName === "apps") root.moveAppSelection(delta)
    else if (pageName === "actions") root.moveActionSelection(delta)
    else if (pageName === "edit") root.moveEditSelection(delta)
    else if (pageName === "confirm") root.moveConfirmFocus(delta)
    else if (pageName === "saved") root.moveSavedFocus(delta)
    else return false
    event.accepted = true
    return true
  }

  function focusCurrentPage() {
    if (root.page === "chooseType") createApplicationButton.forceActiveFocus()
    else if (root.page === "apps") applicationSearch.forceActiveFocus()
    else if (root.page === "actions") root.focusSystemAction(root.actionSelectedIndex)
    else if (root.page === "edit") shortcutSearchField.forceActiveFocus()
    else if (root.page === "capture") {
      if (root.captureModeActive || root.captureModePending) interactionInput.forceActiveFocus()
      else captureStartButton.forceActiveFocus()
    }
    else if (root.page === "confirm") saveShortcutButton.forceActiveFocus()
    else if (root.page === "saved") createAnotherButton.forceActiveFocus()
  }

  function returnFromTargetPage() {
    root.statusMessage = ""
    root.page = root.returnPageAfterTarget
    if (root.page === "edit") root.editCursorActive = false
    Qt.callLater(function() { root.focusCurrentPage() })
  }

  function startEdit() {
    root.statusMessage = ""
    root.statusIsError = false
    root.page = "edit"
    root.shortcutSearch = ""
    root.editSelectedIndex = 0
    root.editCursorActive = false
    root.loadShortcuts()
    Qt.callLater(function() { shortcutSearchField.forceActiveFocus() })
  }

  function editEntry(entry) {
    root.selectedEntry = entry
    root.originalKeys = entry.source === "system" ? entry.keys : (entry.originalKeys || "")
    root.originalDescription = entry.source === "system"
      ? entry.originalDescription
      : (entry.originalDescription || "")
    root.currentKeys = entry.keys || ""
    root.editingId = entry.source === "custom" ? entry.id : ""
    root.appSearch = ""
    root.statusMessage = ""
    root.statusIsError = false
    root.returnPageAfterTarget = "edit"
    root.editCursorActive = false
    root.appCursorActive = false
    if (entry.source === "system") {
      root.selectedDesktopId = ""
      root.selectedAppName = ""
      root.selectedSystemAction = ""
      root.typeChoiceIndex = 0
      root.page = "chooseType"
      Qt.callLater(function() { createApplicationButton.forceActiveFocus() })
      return
    }
    if (entry.kind === "system") {
      root.selectedDesktopId = ""
      root.selectedSystemAction = entry.actionId || ""
      root.selectedAppName = root.systemActionLabel(root.selectedSystemAction)
      root.appCursorActive = false
      root.actionSelectedIndex = 0
      for (var i = 0; i < root.systemActions.length; i++) {
        if (root.systemActions[i].id === root.selectedSystemAction) root.actionSelectedIndex = i
      }
      root.page = "actions"
      Qt.callLater(function() { root.focusSystemAction(root.actionSelectedIndex) })
      return
    }
    root.selectedSystemAction = ""
    root.selectedDesktopId = entry.desktopId || ""
    root.selectedAppName = entry.name || ""
    root.appSelectedIndex = 0
    root.appCursorActive = false
    root.page = "apps"
    Qt.callLater(function() {
      for (var i = 0; i < root.apps.length; i++) {
        var application = root.apps[i] && root.apps[i].entry ? root.apps[i].entry : root.apps[i]
        if (String((application && application.id) || "").replace(/\.desktop$/, "") === root.selectedDesktopId) {
          root.appSelectedIndex = i
          break
        }
      }
      applicationSearch.forceActiveFocus()
      appList.positionViewAtIndex(root.appSelectedIndex, ListView.Contain)
    })
  }

  function selectApplication(entry) {
    if (!entry || !root.appLibrary) return
    if (entry.entry) entry = entry.entry
    root.selectedDesktopId = String(entry.id || "").replace(/\.desktop$/, "")
    root.selectedAppName = String(root.appLibrary.entryName(entry) || entry.name || root.selectedDesktopId)
    root.beginCapture()
  }

  function keepSelectedApplication() {
    if (!root.selectedDesktopId || !root.selectedAppName) return
    root.beginCapture()
  }

  function beginCapture() {
    root.page = "capture"
    root.capturedKeys = root.currentKeys
    root.manualShortcutText = ""
    root.manualEntryActive = false
    root.captureModeActive = false
    root.captureModePending = false
    root.statusMessage = ""
    Qt.callLater(function() { root.startSafeCapture() })
  }

  function startSafeCapture() {
    if (root.captureModeActive || root.captureModePending) return
    root.statusMessage = ""
    root.statusIsError = false
    root.captureModePending = true
    interactionInput.forceActiveFocus()
    root.runHelper(["capture-start"], "capture-start")
  }

  function stopSafeCapture() {
    if (!root.captureModeActive && !root.captureModePending) return
    if (!root.captureModeActive
        && root.hasQueuedHelper("capture-start")
        && root.pendingHelperTask !== "capture-start") {
      root.removeQueuedHelpers("capture-start")
      root.manualEntryActive = false
      root.captureModePending = false
      return
    }
    root.captureModeActive = false
    root.manualEntryActive = false
    root.captureModePending = false
    root.runHelper(["capture-stop"], "capture-stop")
  }

  function keyName(key) {
    if (key >= Qt.Key_A && key <= Qt.Key_Z)
      return String.fromCharCode(key)
    if (key >= Qt.Key_0 && key <= Qt.Key_9)
      return String.fromCharCode(key)
    if (key >= Qt.Key_F1 && key <= Qt.Key_F24)
      return "F" + (key - Qt.Key_F1 + 1)

    switch (key) {
    case Qt.Key_Escape: return "ESCAPE"
    case Qt.Key_Tab: return "TAB"
    case Qt.Key_Backtab: return "TAB"
    case Qt.Key_Backspace: return "BACKSPACE"
    case Qt.Key_Return:
    case Qt.Key_Enter: return "RETURN"
    case Qt.Key_Space: return "SPACE"
    case Qt.Key_Delete: return "DELETE"
    case Qt.Key_Insert: return "INSERT"
    case Qt.Key_Home: return "HOME"
    case Qt.Key_End: return "END"
    case Qt.Key_PageUp: return "PAGEUP"
    case Qt.Key_PageDown: return "PAGEDOWN"
    case Qt.Key_Left: return "LEFT"
    case Qt.Key_Right: return "RIGHT"
    case Qt.Key_Up: return "UP"
    case Qt.Key_Down: return "DOWN"
    case Qt.Key_Print: return "PRINT"
    case Qt.Key_Pause: return "PAUSE"
    case Qt.Key_Menu: return "MENU"
    default: return ""
    }
  }

  function captureKey(event) {
    if (!root.captureModeActive) {
      event.accepted = true
      return
    }
    if ((event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab)
        && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
      root.manualEntryActive = true
      Qt.callLater(function() { manualShortcutInput.forceActiveFocus() })
      event.accepted = true
      return
    }

    if (event.key === Qt.Key_Escape) {
      root.cancelFlow()
      event.accepted = true
      return
    }

    if (event.key === Qt.Key_Shift || event.key === Qt.Key_Control
        || event.key === Qt.Key_Alt || event.key === Qt.Key_AltGr
        || event.key === Qt.Key_Meta || event.key === Qt.Key_Super_L
        || event.key === Qt.Key_Super_R) {
      event.accepted = true
      return
    }

    var modifiers = []
    if (event.modifiers & Qt.MetaModifier) modifiers.push("SUPER")
    if (event.modifiers & Qt.ControlModifier) modifiers.push("CTRL")
    if (event.modifiers & Qt.AltModifier) modifiers.push("ALT")
    if (event.modifiers & Qt.ShiftModifier) modifiers.push("SHIFT")
    if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
        && modifiers.length === 0 && root.currentKeys) {
      root.capturedKeys = root.currentKeys
      root.statusIsError = false
      root.statusMessage = ""
      root.page = "confirm"
      root.confirmFocusIndex = 0
      root.stopSafeCapture()
      Qt.callLater(function() { saveShortcutButton.forceActiveFocus() })
      event.accepted = true
      return
    }
    var key = root.keyName(event.key)

    if (!key) {
      root.statusIsError = true
      root.statusMessage = strings.t("captureUnsupported")
      event.accepted = true
      return
    }
    if (modifiers.length === 0) {
      root.statusIsError = true
      root.statusMessage = strings.t("captureNeedsModifier")
      event.accepted = true
      return
    }

    var order = ["SUPER", "CTRL", "ALT", "SHIFT"]
    var chord = []
    for (var i = 0; i < order.length; i++)
      if (modifiers.indexOf(order[i]) >= 0) chord.push(order[i])
    chord.push(key)
    root.capturedKeys = chord.join(" + ")
    root.statusIsError = false
    root.statusMessage = ""
    root.page = "confirm"
    root.confirmFocusIndex = 0
    root.stopSafeCapture()
    Qt.callLater(function() { saveShortcutButton.forceActiveFocus() })
    event.accepted = true
  }

  function acceptManualShortcut() {
    var parts = root.manualShortcutText.trim().split("+")
    var modifiers = []
    var key = ""
    var allowedModifiers = ["SUPER", "CTRL", "ALT", "SHIFT"]

    for (var i = 0; i < parts.length; i++) {
      var part = parts[i].trim()
      if (!part) {
        root.statusIsError = true
        root.statusMessage = strings.t("manualShortcutInvalid")
        return
      }
      var upper = part.toUpperCase()
      if (allowedModifiers.indexOf(upper) >= 0) {
        if (modifiers.indexOf(upper) >= 0) {
          root.statusIsError = true
          root.statusMessage = strings.t("manualShortcutInvalid")
          return
        }
        modifiers.push(upper)
      } else if (key) {
        root.statusIsError = true
        root.statusMessage = strings.t("manualShortcutInvalid")
        return
      } else {
        key = part
      }
    }

    if (!key || modifiers.length === 0
        || allowedModifiers.indexOf(key.toUpperCase()) >= 0
        || !/^[A-Za-z0-9_:+.-]{1,64}$/.test(key)) {
      root.statusIsError = true
      root.statusMessage = strings.t("manualShortcutInvalid")
      return
    }

    var order = ["SUPER", "CTRL", "ALT", "SHIFT"]
    var chord = []
    for (var j = 0; j < order.length; j++)
      if (modifiers.indexOf(order[j]) >= 0) chord.push(order[j])
    chord.push(key)

    root.capturedKeys = chord.join(" + ")
    root.manualEntryActive = false
    root.statusIsError = false
    root.statusMessage = ""
    root.page = "confirm"
    root.confirmFocusIndex = 0
    root.stopSafeCapture()
    Qt.callLater(function() { saveShortcutButton.forceActiveFocus() })
  }

  function saveShortcut(replaceConflict) {
    if (!root.selectedSystemAction && (!root.selectedDesktopId || !root.selectedAppName)) {
      root.statusIsError = true
      root.statusMessage = strings.t("selectTargetFirst")
      return
    }
    if (!root.capturedKeys) {
      root.statusIsError = true
      root.statusMessage = strings.t("captureShortcutFirst")
      return
    }
    if (helperProcess.running) return
    var task = root.selectedSystemAction ? "save-action" : "save-app"
    var args = root.selectedSystemAction
      ? ["save-action", "--action-id", root.selectedSystemAction, "--keys", root.capturedKeys]
      : ["save-app", "--desktop-id", root.selectedDesktopId, "--name", root.selectedAppName, "--keys", root.capturedKeys]
    if (root.editingId) args.push("--id", root.editingId)
    if (!root.editingId && root.originalKeys) {
      args.push("--original-keys", root.originalKeys)
      args.push("--original-description", root.originalDescription)
    }
    if (replaceConflict) {
      var conflict = root.pendingConflict
      if (!conflict) return
      args.push(
        "--replace-conflict",
        "--replace-conflict-keys", conflict.keys,
        "--replace-conflict-description", conflict.description,
        "--replace-conflict-source", conflict.source,
        "--replace-conflict-record-id", conflict.recordId || ""
      )
    }
    root.statusMessage = ""
    root.runHelper(args, task)
  }

  function requestRemove(entry) {
    if (!entry || entry.source !== "custom") return
    root.removeTargetId = entry.id
    removeDialog.selectedIndex = 0
    removeDialog.opened = true
    Qt.callLater(function() { interactionInput.forceActiveFocus() })
  }

  function removeShortcut() {
    if (!root.removeTargetId) return
    removeDialog.opened = false
    root.runHelper(["remove", "--id", root.removeTargetId], "remove")
  }

  function back() {
    root.statusMessage = ""
    if (root.page === "edit") {
      root.dismiss()
    } else if (root.page === "apps" || root.page === "actions") {
      root.returnFromTargetPage()
    } else if (root.page === "capture") {
      root.stopSafeCapture()
      root.manualEntryActive = false
      root.page = root.selectedSystemAction ? "actions" : "apps"
      Qt.callLater(function() { root.focusCurrentPage() })
    } else if (root.page === "confirm") {
      root.page = "capture"
      Qt.callLater(function() { root.startSafeCapture() })
    } else {
      if (root.page === "chooseType" && root.returnPageAfterTarget === "edit") {
        root.page = "edit"
        Qt.callLater(function() { root.focusCurrentPage() })
      } else {
        root.dismiss()
      }
    }
  }

  function cancelFlow() {
    root.statusMessage = ""
    if (root.page === "confirm") {
      root.page = "capture"
      Qt.callLater(function() { root.startSafeCapture() })
    } else if (root.page === "capture") {
      root.stopSafeCapture()
      root.manualEntryActive = false
      root.page = root.selectedSystemAction ? "actions" : "apps"
      Qt.callLater(function() { root.focusCurrentPage() })
    } else if (root.page === "apps" || root.page === "actions") {
      root.returnFromTargetPage()
    } else if (root.page === "chooseType" && root.returnPageAfterTarget === "edit") {
      root.page = "edit"
      Qt.callLater(function() { root.focusCurrentPage() })
    } else {
      root.dismiss()
    }
  }

  function pageTitle() {
    if (root.page === "chooseType") return strings.t("chooseShortcutType")
    if (root.page === "apps") return strings.t("chooseApplication")
    if (root.page === "actions") return strings.t("chooseSystemAction")
    if (root.page === "edit") return strings.t("chooseShortcut")
    if (root.page === "capture") return strings.t("captureTitle")
    if (root.page === "confirm") return strings.t("selectedShortcut")
    if (root.page === "saved") return strings.t("saved")
    return strings.t("chooseApplication")
  }

  function editDialogKey(event) {
    if (overwriteDialog.opened && (event.key === Qt.Key_Up || event.key === Qt.Key_Down)) {
      overwriteDialog.selectedIndex = overwriteDialog.selectedIndex === 0 ? 1 : 0
      event.accepted = true
      return true
    }
    if (overwriteDialog.opened && overwriteDialog.handleKey(event)) {
      event.accepted = true
      return true
    }
    if (removeDialog.opened && (event.key === Qt.Key_Up || event.key === Qt.Key_Down)) {
      removeDialog.selectedIndex = removeDialog.selectedIndex === 0 ? 1 : 0
      event.accepted = true
      return true
    }
    if (removeDialog.opened && removeDialog.handleKey(event)) {
      event.accepted = true
      return true
    }
    return false
  }

  Process {
    id: helperProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.helperOutput = String(text || "").trim()
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.helperStderr = String(text || "").trim()
    }
    onExited: function(exitCode) { root.handleHelperExit(exitCode) }
  }

  OverlayWindow {
    id: panel
    shown: root.opened
    shownKeyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    WlrLayershell.namespace: "splashy-keybindings"

    Rectangle {
      anchors.fill: parent
      color: Commons.Color.menu.scrim

      MouseArea {
        anchors.fill: parent
        onClicked: root.dismiss()
      }
    }

    BorderSurface {
      id: card
      width: Math.min(Style.space(480), panel.width - Style.gapsOut * 2)
      height: Math.min(root.page === "apps" || root.page === "actions" || root.page === "edit"
        ? Style.space(500) : root.page === "capture" ? Style.space(500) : Style.space(360),
        panel.height - Style.gapsOut * 2)
      anchors.centerIn: parent
      color: Commons.Color.menu.background
      borderSpec: Border.surfaceSpec("menu", "border", Commons.Color.menu.border, Math.max(1, Style.space(2)))
      padding: Style.spacing.panelPadding
      radius: Style.cornerRadius

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
      }

      Item {
        id: keyCatcher
        anchors.fill: parent
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.editDialogKey(event)) return
          if (root.page === "capture") {
            if (root.manualEntryActive) {
              if (event.key === Qt.Key_Escape) {
                root.cancelFlow()
                event.accepted = true
              } else event.accepted = false
              return
            }
            if (!root.captureModeActive) return
            root.captureKey(event)
            return
          }
          if (root.page === "apps") {
            if (event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
              root.moveAppSelection(event.key === Qt.Key_Up ? -1 : 1)
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.selectCurrentApplication()
              event.accepted = true
            }
            if (event.accepted) return
          } else if (root.page === "edit") {
            if (event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
              root.moveEditSelection(event.key === Qt.Key_Up ? -1 : 1)
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.selectCurrentShortcut()
              event.accepted = true
            }
            if (event.accepted) return
          }
          if (root.page === "confirm" && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
            root.saveShortcut()
            event.accepted = true
            return
          }
          if (event.key === Qt.Key_Escape) {
            root.cancelFlow()
            event.accepted = true
          }
        }

        TextInput {
          id: interactionInput
          x: 0
          y: 0
          width: 1
          height: 1
          visible: (root.page === "capture" && (root.captureModeActive || root.captureModePending))
            || overwriteDialog.opened || removeDialog.opened
          opacity: 0
          focus: visible && !(root.page === "capture" && root.manualEntryActive)
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) {
            if (root.page === "capture") {
              if (root.captureModeActive) root.captureKey(event)
              else event.accepted = true
            } else {
              root.editDialogKey(event)
              event.accepted = true
            }
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        anchors.topMargin: card.contentTopInset
        anchors.bottomMargin: card.contentBottomInset
        spacing: Style.spacing.md

        Row {
          id: headerRow
          width: parent.width
          height: Style.space(42)
          spacing: Style.spacing.sm

          Text {
            width: parent.width - closeButton.implicitWidth - parent.spacing
            height: parent.height
            textFormat: Text.PlainText
            text: root.pageTitle()
            color: Commons.Color.menu.text
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
          }

          Button {
            id: closeButton
            text: "×"
            tooltipText: strings.t("close")
            fontFamily: root.fontFamily
            foreground: Commons.Color.menu.text
            fontSize: Style.font.heading
            width: Style.space(34)
            height: Style.space(34)
            focusable: true
            Keys.onPressed: function(event) { root.handleButtonNavigation(event, root.page) }
            onClicked: root.dismiss()
          }
        }

        Item {
          width: parent.width
          height: parent.height - headerRow.height - parent.spacing * 2
            - (statusRow.visible ? statusRow.height : 0)

          Column {
            visible: root.page === "chooseType"
            anchors.fill: parent
            spacing: Style.spacing.sm

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.originalKeys
                ? strings.t("editing").arg(root.originalDescription)
                : strings.t("chooseShortcutTypeDetail")
              color: Commons.Color.menu.text
              opacity: 0.72
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Button {
              id: createApplicationButton
              width: parent.width
              text: strings.t("openApplication")
              iconText: "󰀻"
              fontFamily: root.fontFamily
              foreground: Commons.Color.menu.text
              leftAlign: true
              focusable: true
              Keys.onPressed: function(event) { root.handleButtonNavigation(event, "chooseType") }
              onActiveFocusChanged: if (activeFocus) root.typeChoiceIndex = 0
              onClicked: root.startApplicationCreate()
            }

            Button {
              id: systemActionButton
              width: parent.width
              text: strings.t("systemAction")
              iconText: ""
              fontFamily: root.fontFamily
              foreground: Commons.Color.menu.text
              leftAlign: true
              focusable: true
              Keys.onPressed: function(event) { root.handleButtonNavigation(event, "chooseType") }
              onActiveFocusChanged: if (activeFocus) root.typeChoiceIndex = 1
              onClicked: root.startActionCreate()
            }

            Column {
              width: parent.width
              spacing: Style.spacing.xs

              Button {
                id: customCommandButton
                width: parent.width
                text: strings.t("customCommand")
                iconText: "󰏫"
                fontFamily: root.fontFamily
                foreground: Commons.Color.menu.text
                leftAlign: true
                focusable: true
                Keys.onPressed: function(event) { root.handleButtonNavigation(event, "chooseType") }
                onActiveFocusChanged: if (activeFocus) root.typeChoiceIndex = 2
                onClicked: root.openCustomConfig()
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: strings.t("customCommandDetail")
                color: Commons.Color.menu.text
                opacity: 0.62
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }

          Column {
            visible: root.page === "apps"
            anchors.fill: parent
            spacing: Style.spacing.sm

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.editingId || root.originalKeys ? strings.t("editing").arg(root.originalDescription || root.selectedAppName) : strings.t("selectApplication")
              color: Commons.Color.menu.text
              opacity: 0.72
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Button {
              visible: root.selectedDesktopId !== "" && root.selectedAppName !== ""
              width: parent.width
              text: strings.t("shortcutFor").arg(root.selectedAppName)
              iconText: "󰌌"
              fontFamily: root.fontFamily
              foreground: Commons.Color.menu.text
              leftAlign: true
              focusable: true
              Keys.onPressed: function(event) { root.handleButtonNavigation(event, "apps") }
              onClicked: root.keepSelectedApplication()
            }

            Item {
              id: applicationSearchContainer
              width: parent.width
              height: Style.space(34)

              FilterInput {
                id: applicationSearch
                anchors.fill: parent
                keyHandler: keyCatcher
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                color: Commons.Color.menu.text
                text: root.appSearch
                Keys.onUpPressed: function(event) {
                  root.moveAppSelection(-1)
                  event.accepted = true
                }
                Keys.onDownPressed: function(event) {
                  root.moveAppSelection(1)
                  event.accepted = true
                }
                Keys.onEscapePressed: function(event) {
                  root.cancelFlow()
                  event.accepted = true
                }
                onAccepted: root.selectCurrentApplication()
                onTextChanged: {
                  root.appSearch = text
                  root.appSelectedIndex = 0
                  root.appCursorActive = false
                }
              }

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.md
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: !applicationSearch.text && !applicationSearch.preeditText
                textFormat: Text.PlainText
                text: strings.t("searchApplications")
                color: Commons.Color.menu.text
                opacity: 0.62
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                verticalAlignment: Text.AlignVCenter
                enabled: false
              }
            }

            Item {
              width: parent.width
              height: parent.height - applicationSearchContainer.height - parent.spacing * 2
                - (root.selectedDesktopId !== "" && root.selectedAppName !== "" ? Style.space(46) : 0)

              ListView {
                id: appList
                anchors.fill: parent
                clip: true
                spacing: Style.spacing.xs
                model: root.apps
                currentIndex: root.appSelectedIndex
                onCurrentIndexChanged: {
                  if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
                }
                boundsBehavior: Flickable.StopAtBounds

                delegate: Item {
                  id: appRow
                  required property int index
                  required property var modelData
                  focus: root.appCursorActive && root.appSelectedIndex === appRow.index
                  Keys.onUpPressed: function(event) {
                    root.moveAppSelection(-1)
                    event.accepted = true
                  }
                  Keys.onDownPressed: function(event) {
                    root.moveAppSelection(1)
                    event.accepted = true
                  }
                  Keys.onReturnPressed: function(event) {
                    root.selectCurrentApplication()
                    event.accepted = true
                  }
                  Keys.onEnterPressed: function(event) {
                    root.selectCurrentApplication()
                    event.accepted = true
                  }
                  Keys.onEscapePressed: function(event) {
                    root.cancelFlow()
                    event.accepted = true
                  }
                  width: appList.width
                  height: Style.space(52)

                  // AppLibrary returns ranked search rows; the actual desktop
                  // entry (id, icon, localized name) lives under `entry`.
                  readonly property var applicationEntry: appRow.modelData && appRow.modelData.entry
                    ? appRow.modelData.entry
                    : appRow.modelData
                  readonly property bool appSelected: String((appRow.applicationEntry && appRow.applicationEntry.id) || "")
                    .replace(/\.desktop$/, "") === root.selectedDesktopId
                  readonly property bool keyboardSelected: appRow.index === root.appSelectedIndex

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: appRow.keyboardSelected
                      ? Style.selectedFillFor(Commons.Color.menu.text, Commons.Color.accent)
                      : (appRow.appSelected || appHover.containsMouse
                        ? Style.hoverFillFor(Commons.Color.menu.text, Commons.Color.accent)
                        : "transparent")
                  }

                  Image {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.spacing.md
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(30)
                    height: width
                    sourceSize: Qt.size(width * 2, height * 2)
                    source: root.appLibrary && appRow.applicationEntry
                      ? root.appLibrary.iconSource(appRow.applicationEntry.icon)
                      : ""
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                  }

                  Text {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(56)
                    anchors.right: parent.right
                    anchors.rightMargin: Style.spacing.md
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: root.appLibrary && appRow.applicationEntry
                      ? root.appLibrary.entryName(appRow.applicationEntry)
                      : String((appRow.applicationEntry && appRow.applicationEntry.name) || "")
                    color: Commons.Color.menu.text
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }

                  MouseArea {
                    id: appHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.selectApplication(appRow.applicationEntry)
                  }
                }
              }

              Text {
                anchors.centerIn: parent
                visible: root.apps.length === 0
                textFormat: Text.PlainText
                text: root.loading ? strings.t("loading") : strings.t("noApplications")
                color: Commons.Color.menu.text
                opacity: 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }

          Column {
            visible: root.page === "actions"
            anchors.fill: parent
            spacing: Style.spacing.sm

            Text {
              id: actionPrompt
              width: parent.width
              textFormat: Text.PlainText
              text: root.editingId || root.originalKeys
                ? strings.t("editing").arg(root.selectedAppName)
                : strings.t("chooseSystemActionDetail")
              color: Commons.Color.menu.text
              opacity: 0.72
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Button {
              visible: root.selectedSystemAction !== ""
              width: parent.width
              text: strings.t("shortcutFor").arg(root.selectedAppName)
              iconText: "󰌌"
              fontFamily: root.fontFamily
              foreground: Commons.Color.menu.text
              leftAlign: true
              focusable: true
              Keys.onPressed: function(event) { root.handleButtonNavigation(event, "actions") }
              onClicked: root.keepSelectedSystemAction()
            }

            ListView {
              id: systemActionList
              width: parent.width
              height: parent.height - actionPrompt.height - parent.spacing * 2
                - (root.selectedSystemAction !== "" ? Style.space(46) : 0)
              clip: true
              spacing: Style.spacing.xs
              model: root.systemActions
              currentIndex: root.actionSelectedIndex
              onCurrentIndexChanged: {
                if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
              }
              boundsBehavior: Flickable.StopAtBounds

              delegate: Item {
                id: systemActionRow
                required property int index
                required property var modelData
                property alias keyboardButton: actionButton
                width: systemActionList.width
                height: Style.space(62)

                Button {
                  id: actionButton
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  height: Style.space(42)
                  text: strings.t(systemActionRow.modelData.labelKey)
                  iconText: systemActionRow.modelData.icon
                  fontFamily: root.fontFamily
                  foreground: Commons.Color.menu.text
                  leftAlign: true
                  focusable: true
                  selected: root.actionSelectedIndex === systemActionRow.index
                  Keys.onPressed: function(event) { root.handleButtonNavigation(event, "actions") }
                  onActiveFocusChanged: if (activeFocus) root.actionSelectedIndex = systemActionRow.index
                  onClicked: root.selectSystemAction(systemActionRow.modelData.id)
                }

                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(42)
                  anchors.right: parent.right
                  anchors.rightMargin: Style.spacing.md
                  anchors.bottom: parent.bottom
                  height: Style.space(18)
                  textFormat: Text.PlainText
                  text: strings.t(systemActionRow.modelData.detailKey)
                  color: Commons.Color.menu.text
                  opacity: 0.62
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  verticalAlignment: Text.AlignVCenter
                  enabled: false
                }
              }
            }
          }

          Column {
            visible: root.page === "edit"
            anchors.fill: parent
            spacing: Style.spacing.sm

            Item {
              id: shortcutSearchContainer
              width: parent.width
              height: Style.space(34)

              FilterInput {
                id: shortcutSearchField
                anchors.fill: parent
                keyHandler: keyCatcher
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                color: Commons.Color.menu.text
                text: root.shortcutSearch
                Keys.onUpPressed: function(event) {
                  root.moveEditSelection(-1)
                  event.accepted = true
                }
                Keys.onDownPressed: function(event) {
                  root.moveEditSelection(1)
                  event.accepted = true
                }
                Keys.onEscapePressed: function(event) {
                  root.cancelFlow()
                  event.accepted = true
                }
                onAccepted: root.selectCurrentShortcut()
                onTextChanged: {
                  root.shortcutSearch = text
                  root.editSelectedIndex = 0
                  root.editCursorActive = false
                }
              }

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.md
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: !shortcutSearchField.text && !shortcutSearchField.preeditText
                textFormat: Text.PlainText
                text: strings.t("searchShortcuts")
                color: Commons.Color.menu.text
                opacity: 0.62
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                verticalAlignment: Text.AlignVCenter
                enabled: false
              }
            }

            Item {
              width: parent.width
              height: parent.height - shortcutSearchContainer.height - parent.spacing

              ListView {
                id: shortcutList
                anchors.fill: parent
                clip: true
                spacing: Style.spacing.xs
                model: root.shortcutEntries
                currentIndex: root.editSelectedIndex
                onCurrentIndexChanged: {
                  if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
                }
                boundsBehavior: Flickable.StopAtBounds

                delegate: Item {
                  id: shortcutRow
                  required property int index
                  required property var modelData
                  property alias focusButton: editButton
                  width: shortcutList.width
                  height: Style.space(62)

                  Button {
                    id: editButton
                    anchors.left: parent.left
                    anchors.right: modelData.source === "custom" ? removeButton.left : parent.right
                    anchors.rightMargin: modelData.source === "custom" ? Style.spacing.xs : 0
                    anchors.top: parent.top
                    height: parent.height
                    text: String(modelData.name || "")
                    iconText: modelData.source === "custom"
                      ? (modelData.kind === "system" ? "" : "󰌌")
                      : ""
                    fontFamily: root.fontFamily
                    foreground: Commons.Color.menu.text
                    leftAlign: true
                    focusable: true
                    selected: root.editSelectedIndex === shortcutRow.index
                    Keys.onPressed: function(event) { root.handleButtonNavigation(event, "edit") }
                    onActiveFocusChanged: if (activeFocus) root.editSelectedIndex = shortcutRow.index
                    onClicked: root.editEntry(modelData)
                  }

                  Text {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(42)
                    anchors.right: modelData.source === "custom" ? removeButton.left : parent.right
                    anchors.rightMargin: Style.spacing.md
                    anchors.bottom: parent.bottom
                    height: Style.space(19)
                    textFormat: Text.PlainText
                    text: String(modelData.keys || "") + " · "
                      + strings.t(modelData.source === "custom" ? "sourceCustom" : "sourceOmarchy")
                    color: Commons.Color.menu.text
                    opacity: 0.62
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    verticalAlignment: Text.AlignVCenter
                    enabled: false
                  }

                  Button {
                    id: removeButton
                    visible: modelData.source === "custom"
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(38)
                    height: Style.space(38)
                    text: "×"
                    tooltipText: strings.t("remove")
                    fontFamily: root.fontFamily
                    foreground: Commons.Color.menu.text
                    fontSize: Style.font.heading
                    focusable: true
                    Keys.onPressed: function(event) { root.handleButtonNavigation(event, "edit") }
                    onActiveFocusChanged: if (activeFocus) root.editSelectedIndex = shortcutRow.index
                    onClicked: root.requestRemove(modelData)
                  }
                }
              }

              Text {
                anchors.centerIn: parent
                visible: !root.loading && root.shortcutEntries.length === 0
                textFormat: Text.PlainText
                text: root.customEntries.length === 0 && root.systemEntries.length === 0
                  ? strings.t("noCustomShortcuts")
                  : strings.t("noShortcuts")
                color: Commons.Color.menu.text
                opacity: 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                anchors.centerIn: parent
                visible: root.loading && root.shortcutEntries.length === 0
                textFormat: Text.PlainText
                text: strings.t("loading")
                color: Commons.Color.menu.text
                opacity: 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }

          Column {
            visible: root.page === "capture"
            anchors.fill: parent
            spacing: Style.spacing.lg

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.selectedAppName ? strings.t("shortcutFor").arg(root.selectedAppName) : strings.t("captureTitle")
              color: Commons.Color.menu.text
              opacity: 0.72
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Button {
              id: captureStartButton
              visible: !root.captureModeActive && !root.captureModePending
              width: parent.width
              text: strings.t("retryCaptureMode")
              iconText: "󰌌"
              fontFamily: root.fontFamily
              foreground: Commons.Color.menu.text
              leftAlign: true
              focusable: true
              enabled: !root.captureModePending && !helperProcess.running
              Keys.onPressed: function(event) { root.handleButtonNavigation(event, "capture") }
              onClicked: root.startSafeCapture()
            }

            Text {
              width: parent.width
              visible: root.captureModePending
              textFormat: Text.PlainText
              text: strings.t("startingCaptureMode")
              color: Commons.Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              visible: root.captureModeActive
              textFormat: Text.PlainText
              text: strings.t("captureModeActive")
              color: Commons.Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            BorderSurface {
              width: parent.width
              height: Style.space(112)
              color: Style.controlFill(false, false, Commons.Color.menu.text, Commons.Color.accent)
              borderSpec: Border.controlSpec("normal", Commons.Color.menu.text, Commons.Color.accent)
              radius: Style.cornerRadius

              Column {
                anchors.centerIn: parent
                spacing: Style.spacing.sm

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: strings.t("captureTitle")
                  color: Commons.Color.menu.text
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.bold: true
                }

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: root.capturedKeys || strings.t("captureHelp")
                  color: Commons.Color.menu.text
                  opacity: root.capturedKeys ? 1 : 0.7
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: strings.t("captureHelp")
              color: Commons.Color.menu.text
              opacity: 0.62
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: strings.t("captureManualHelp")
              color: Commons.Color.menu.text
              opacity: 0.72
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            BorderSurface {
              width: parent.width
              height: Style.space(42)
              color: Style.controlFill(false, false, Commons.Color.menu.text, Commons.Color.accent)
              borderSpec: Border.controlSpec("normal", Commons.Color.menu.text, Commons.Color.accent)
              radius: Style.cornerRadius

              FilterInput {
                id: manualShortcutInput
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.spacing.md
                anchors.rightMargin: Style.spacing.md
                anchors.verticalCenter: parent.verticalCenter
                height: parent.height
                keyHandler: keyCatcher
                focus: false
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                color: Commons.Color.menu.text
                text: root.manualShortcutText
                onActiveFocusChanged: {
                  if (activeFocus) {
                    root.stopSafeCapture()
                    root.manualEntryActive = true
                  } else {
                    root.manualEntryActive = false
                  }
                }
                onTextChanged: root.manualShortcutText = text
                onAccepted: root.acceptManualShortcut()
              }

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.md
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: !manualShortcutInput.text && !manualShortcutInput.preeditText
                textFormat: Text.PlainText
                text: strings.t("captureManualPlaceholder")
                color: Commons.Color.menu.text
                opacity: 0.56
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                verticalAlignment: Text.AlignVCenter
                enabled: false
              }
            }

            Button {
              id: keepCurrentShortcutButton
              visible: root.currentKeys !== ""
              width: parent.width
              text: strings.t("shortcutFor").arg(root.currentKeys)
              iconText: "󰌌"
              fontFamily: root.fontFamily
              foreground: Commons.Color.menu.text
              leftAlign: true
              focusable: true
              Keys.onPressed: function(event) { root.handleButtonNavigation(event, "capture") }
              onClicked: {
                root.capturedKeys = root.currentKeys
                root.page = "confirm"
                root.confirmFocusIndex = 0
                root.stopSafeCapture()
                Qt.callLater(function() { saveShortcutButton.forceActiveFocus() })
              }
            }
          }

          Column {
            visible: root.page === "confirm"
            anchors.fill: parent
            spacing: Style.spacing.lg

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: strings.t("shortcutFor").arg(root.selectedAppName)
              color: Commons.Color.menu.text
              opacity: 0.72
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            BorderSurface {
              width: parent.width
              height: Style.space(100)
              color: Style.controlFill(false, false, Commons.Color.menu.text, Commons.Color.accent)
              borderSpec: Border.controlSpec("normal", Commons.Color.menu.text, Commons.Color.accent)
              radius: Style.cornerRadius

              Text {
                anchors.centerIn: parent
                width: parent.width - Style.space(24)
                textFormat: Text.PlainText
                text: root.capturedKeys
                color: Commons.Color.menu.text
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                font.bold: true
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
              }
            }

            Button {
              id: saveShortcutButton
              width: parent.width
              text: strings.t("save")
              iconText: "󰄬"
              fontFamily: root.fontFamily
              foreground: Commons.Color.menu.text
              leftAlign: true
              focusable: true
              enabled: root.capturedKeys !== "" && !helperProcess.running
              Keys.onPressed: function(event) { root.handleButtonNavigation(event, "confirm") }
              onActiveFocusChanged: if (activeFocus) root.confirmFocusIndex = 0
              onClicked: root.saveShortcut()
            }

            Button {
              id: confirmBackButton
              width: parent.width
              text: strings.t("back")
              iconText: "󰁍"
              fontFamily: root.fontFamily
              foreground: Commons.Color.menu.text
              leftAlign: true
              focusable: true
              Keys.onPressed: function(event) { root.handleButtonNavigation(event, "confirm") }
              onActiveFocusChanged: if (activeFocus) root.confirmFocusIndex = 1
              onClicked: root.back()
            }
          }

          Column {
            visible: root.page === "saved"
            anchors.fill: parent
            spacing: Style.spacing.md

            BorderSurface {
              width: parent.width
              height: Style.space(112)
              color: Style.selectedFillFor(Commons.Color.menu.text, Commons.Color.accent)
              borderSpec: Border.controlSpec("selected", Commons.Color.menu.text, Commons.Color.accent)
              radius: Style.cornerRadius

              Column {
                anchors.centerIn: parent
                spacing: Style.spacing.xs

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: "󰄬"
                  color: Commons.Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                }

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: strings.t("saved")
                  color: Commons.Color.menu.text
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.bold: true
                }
              }
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: strings.t("savedDetail").arg(root.capturedKeys).arg(root.selectedAppName)
              color: Commons.Color.menu.text
              opacity: 0.78
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }

            Button {
              id: createAnotherButton
              width: parent.width
              text: strings.t("createAnother")
              iconText: ""
              fontFamily: root.fontFamily
              foreground: Commons.Color.menu.text
              leftAlign: true
              focusable: true
              Keys.onPressed: function(event) { root.handleButtonNavigation(event, "saved") }
              onActiveFocusChanged: if (activeFocus) root.savedFocusIndex = 0
              onClicked: root.startCreate()
            }

            Button {
              id: closeSavedButton
              width: parent.width
              text: strings.t("closeMenu")
              iconText: "󰅖"
              fontFamily: root.fontFamily
              foreground: Commons.Color.menu.text
              leftAlign: true
              focusable: true
              Keys.onPressed: function(event) { root.handleButtonNavigation(event, "saved") }
              onActiveFocusChanged: if (activeFocus) root.savedFocusIndex = 1
              onClicked: root.dismiss()
            }
          }
        }

        Row {
          id: statusRow
          width: parent.width
          height: Style.space(24)
          spacing: Style.spacing.sm
          visible: root.statusMessage !== ""

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.statusMessage
            color: root.statusIsError ? Commons.Color.urgent : Commons.Color.menu.text
            opacity: root.statusIsError ? 1 : 0.72
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            verticalAlignment: Text.AlignVCenter
          }
        }
      }

      ConfirmDialog {
        id: overwriteDialog
        anchors.fill: parent
        opened: false
        message: root.pendingConflict
          ? strings.t("conflictConfirm").arg(root.pendingConflict.keys).arg(root.pendingConflict.description)
          : ""
        cancelText: strings.t("cancel")
        confirmText: strings.t("overwrite")
        onCanceled: {
          opened = false
          root.pendingConflict = null
          root.statusIsError = false
          root.statusMessage = strings.t("conflictCanceled")
          Qt.callLater(function() { saveShortcutButton.forceActiveFocus() })
        }
        onConfirmed: {
          opened = false
          root.saveShortcut(true)
        }
      }

      ConfirmDialog {
        id: removeDialog
        anchors.fill: parent
        opened: false
        message: strings.t("removeConfirm")
        cancelText: strings.t("cancel")
        confirmText: strings.t("remove")
        onCanceled: {
          opened = false
          Qt.callLater(function() { shortcutSearchField.forceActiveFocus() })
        }
        onConfirmed: root.removeShortcut()
      }
    }
  }

  Connections {
    target: root.appLibrary
    function onAppsChanged() { root.appsRevision++ }
  }

}
