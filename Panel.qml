import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Grok usage in the bar: the official Grok mark plus the weekly plan meter,
// and a popup with the percentage, reset countdown, plan tier, on-demand /
// prepaid amounts, and local session activity.
//
// The numbers come from the billing snapshot the installed Grok CLI already
// writes to ~/.grok/logs/unified.jsonl when a session starts. There is no API
// key, no network request, and no auth token: the widget only reads that log
// and the numeric session ledgers under ~/.grok/sessions.
Panel {
  id: root
  moduleName: "crueber.grok-usage"
  ipcTarget: "grok-usage"
  manageIpc: false
  // The custom ShellIpc below owns the target. `omarchy-shell shell toggle
  // crueber.grok-usage` also routes here through the bar's summon path.

  // ------------------------------------------------------------------ theme

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false

  // --------------------------------------------------------------- settings
  // Inline on the widget's shell.json layout entry; see manifest.json.

  readonly property int refreshIntervalSec: Model.clampInt(setting("refreshIntervalSec", 300), 60, 3600, 300)
  readonly property int warnPercent: Model.clampInt(setting("warnPercent", 70), 0, 100, 70)
  readonly property int criticalPercent: Model.clampInt(setting("criticalPercent", 90), 0, 100, 90)
  readonly property string barStyleRaw: String(setting("barStyle", "bars"))
  readonly property string barStyle: ["bars", "text", "icon"].indexOf(barStyleRaw) >= 0 ? barStyleRaw : "bars"
  readonly property bool showWeekly: setting("showWeekly", true) !== false
  readonly property bool showBot: setting("showBot", true) !== false
  readonly property bool showLocalStats: setting("showLocalStats", true) !== false
  readonly property string warningColor: String(setting("warningColor", "#f67400"))
  readonly property string criticalColor: String(setting("criticalColor", ""))
  readonly property string nodeCommand: String(setting("nodeCommand", ""))
  readonly property string grokHome: String(setting("grokHome", ""))
  readonly property string botHome: String(setting("botHome", ""))
  readonly property string rightClickCommand: String(setting("onRightClick", ""))

  readonly property string executable: nodeCommand !== "" ? nodeCommand : "node"
  readonly property string helperPath: {
    var value = String(Qt.resolvedUrl("scripts/collect.js"))
    if (value.indexOf("file://") === 0) value = value.slice(7)
    try { value = decodeURIComponent(value) } catch (e) {}
    return value
  }

  // ------------------------------------------------------------------- data

  property var report: null
  property string errorText: ""
  property string lastErrorMessage: ""
  property string stderrText: ""
  property bool gotOutput: false
  property double lastFetchMs: 0
  property double lastAttemptMs: 0
  property int fetchFailures: 0
  property double nowMs: Date.now()

  property bool cacheLoadAttempted: false
  property bool settingsReady: false
  property bool startupDone: false
  property bool pollLeader: false
  property int consumedSeq: 0

  // Last successful read and last attempt, kept on disk so a shell restart
  // paints immediately and waits out the rest of the interval.
  readonly property string cacheHome: {
    var xdg = Quickshell.env("XDG_CACHE_HOME")
    if (xdg) return xdg
    var home = Quickshell.env("HOME")
    return home ? home + "/.cache" : "/tmp"
  }
  readonly property string cacheDir: root.cacheHome + "/grok-usage"
  readonly property string cachePath: root.cacheDir + "/usage.json"

  readonly property var allWindows: Model.windows(report, warnPercent, criticalPercent)
  readonly property var barWindows: Model.filterWindows(allWindows, { weekly: showWeekly, bot: showBot })
  readonly property var highest: Model.highest(barWindows.length > 0 ? barWindows : allWindows)
  readonly property bool hasData: report !== null && report.weekly !== null
  readonly property bool expired: report !== null && report.weekly !== null && report.weekly.expired === true
  readonly property bool alarming: highest !== null && highest.state === "critical"
  readonly property bool busy: fetchProc.running
  readonly property string compactText: Model.compactText(barWindows)
  readonly property string refreshNote: report !== null && lastErrorMessage !== "" ? "read failed" : ""
  readonly property string tooltipText: {
    var base = hasData
      ? Model.tooltip(allWindows, nowMs)
      : (errorText !== "" ? "Grok usage: " + errorText : "Grok usage: reading the local snapshot")
    if (showMonthSection) {
      var turns = localMonth.turns === 1 ? "1 turn" : localMonth.turns + " turns"
      base += "\nLast 30 days locally: " + turns + " · " + Model.formatCost(localMonth.costUsd)
    }
    return base
  }

  readonly property string heroMeta: {
    if (!report) return errorText !== "" ? "No snapshot" : "Reading snapshot"
    var parts = []
    if (report.tier !== "") parts.push(report.tier)
    parts.push(expired ? "New period" : Model.periodName(report.period))
    return parts.join(" · ")
  }
  readonly property string heroDetail: highest !== null && hasData
    ? Model.percentText(highest.percent)
    : ""

  readonly property string footerText: {
    var parts = []
    var checked = Model.updatedText(root.lastFetchMs, root.nowMs)
    if (checked !== "") parts.push(checked)
    if (root.report) {
      var snap = Model.snapshotText(root.report.snapshotAt, root.nowMs)
      if (snap !== "") parts.push(snap)
    }
    if (root.refreshNote !== "") parts.push(root.refreshNote)
    parts.push("local read")
    return parts.join(" · ")
  }

  readonly property var local: report ? report.local : null
  readonly property bool hasLocal: showLocalStats && local !== null && local.tokens > 0
  readonly property var localMonth: report ? report.localMonth : null
  readonly property var bot: report ? report.bot : null
  readonly property bool hasLocalMonth: showLocalStats && localMonth !== null && localMonth.turns > 0
  readonly property bool showMonthSection: hasLocalMonth && report !== null && report.period !== "month"
  readonly property var onDemand: report ? report.onDemand : null
  readonly property bool hasBilling: onDemand !== null
    && (onDemand.cap > 0 || onDemand.used > 0 || onDemand.prepaid > 0)

  function stateColor(state) {
    if (state === "critical") return criticalColor !== "" ? criticalColor : urgent
    if (state === "warning") return warningColor !== "" ? warningColor : foreground
    return foreground
  }

  // Absolute reset clock beside the countdown. Same-day resets only need the
  // time; anything further out gets the day as well.
  function clockAt(ms) {
    var target = Number(ms) || 0
    if (target <= 0) return ""
    var date = new Date(target)
    var now = new Date()
    var sameDay = date.getFullYear() === now.getFullYear()
      && date.getMonth() === now.getMonth()
      && date.getDate() === now.getDate()
    return date.toLocaleString(Qt.locale(Commons.I18n.formatLocale), sameDay ? "HH:mm" : "d MMM HH:mm")
  }

  // ------------------------------------------------------------ cache & read

  function loadCache(raw) {
    var cached = Model.parseCache(raw, Date.now())
    if (!cached) return
    root.lastFetchMs = Math.max(root.lastFetchMs, cached.fetchedAt)
    root.lastAttemptMs = Math.max(root.lastAttemptMs, cached.attemptedAt)
    root.fetchFailures = Math.max(root.fetchFailures, cached.failures)
    Model.pollSeed(cached.fetchedAt, cached.attemptedAt, cached.failures)

    if (cached.report) {
      root.report = cached.report
      root.lastErrorMessage = cached.error
      root.errorText = ""
      root.nowMs = Date.now()
    } else if (cached.error !== "") {
      root.lastErrorMessage = cached.error
      root.errorText = cached.error
    }
  }

  function writeCache() {
    if (!root.cacheLoadAttempted) return
    cacheFile.setText(Model.serializeCache(
      root.report,
      root.lastFetchMs,
      root.lastAttemptMs,
      root.fetchFailures,
      root.lastErrorMessage
    ))
  }

  function nextAutoDelayMs() {
    var fetchedAt = Math.max(root.lastFetchMs, Model.pollState.fetchedAt)
    var attemptedAt = Math.max(root.lastAttemptMs, Model.pollState.attemptedAt)
    var failures = Math.max(root.fetchFailures, Model.pollState.failures)
    return Model.autoDelayMs(fetchedAt, attemptedAt, failures, root.refreshIntervalSec * 1000, Date.now())
  }

  function scheduleNextPoll(delayMs) {
    if (!root.pollLeader) return
    poll.interval = Math.max(250, Math.round(Number(delayMs) || 0))
    poll.restart()
  }

  function startPolling() {
    if (!root.cacheLoadAttempted || !root.settingsReady) {
      Qt.callLater(root.startPolling)
      return
    }
    root.scheduleNextPoll(root.nextAutoDelayMs())
  }

  function applyResult(result) {
    root.report = result.report || null
    root.lastFetchMs = Number(result.fetchedAt) || 0
    root.lastAttemptMs = Number(result.attemptedAt) || 0
    root.fetchFailures = Math.round(Number(result.failures) || 0)
    root.errorText = String(result.errorText || "")
    root.lastErrorMessage = String(result.error || "")
    root.nowMs = Date.now()
  }

  function publishResult(result) {
    root.applyResult(result)
    Model.pollPublish(root, result)
    root.writeCache()
    root.scheduleNextPoll(root.nextAutoDelayMs())
  }

  function handleSuccess(parsed, now) {
    root.publishResult({
      report: parsed,
      fetchedAt: now,
      attemptedAt: now,
      failures: 0,
      errorText: "",
      error: ""
    })
  }

  function handleFailure(message, now) {
    var failures = Math.min(20, root.fetchFailures + 1)
    var dataPresent = root.report !== null
    root.publishResult({
      report: root.report,
      fetchedAt: root.lastFetchMs,
      attemptedAt: now,
      failures: failures,
      errorText: dataPresent ? "" : message,
      error: message
    })
  }

  function fetchCommand() {
    var command = Model.shellQuote(root.executable) + " " + Model.shellQuote(root.helperPath)
    if (root.grokHome !== "") command += " --home " + Model.shellQuote(root.grokHome)
    if (root.botHome !== "") command += " --bot-home " + Model.shellQuote(root.botHome)
    return command
  }

  // The one place that starts a process. The attempt timestamp is written to
  // disk before the read so a crash or shell restart within the cooldown is
  // remembered.
  function spawnFetch() {
    root.gotOutput = false
    root.stderrText = ""
    root.lastAttemptMs = Date.now()
    root.writeCache()
    fetchProc.command = ["/bin/sh", "-lc", root.fetchCommand()]
    fetchProc.running = true
  }

  // Scheduled polls, panel opens, middle click, `r`, and IPC all funnel through
  // here so the automatic 60 s / manual 30 s floors are enforced once.
  function requestFetch(kind) {
    if (!root.pollLeader || fetchProc.running) return

    var now = Date.now()
    if (root.lastAttemptMs > 0) {
      var gap = now - root.lastAttemptMs
      var minGap = kind === "manual" ? Model.FORCE_MIN_MS : Model.AUTO_MIN_MS
      if (gap < minGap) {
        if (kind === "manual") {
          manualCatchup.interval = Math.max(1000, Math.round(minGap - gap) + 250)
          manualCatchup.restart()
        } else {
          root.scheduleNextPoll(minGap - gap)
        }
        return
      }
    }

    if (kind === "auto") {
      var delay = root.nextAutoDelayMs()
      if (delay > 1500) {
        root.scheduleNextPoll(delay)
        return
      }
    }
    root.spawnFetch()
  }

  function refreshNow() {
    if (root.pollLeader) {
      root.requestFetch("manual")
      return
    }
    var leader = Model.pollLeaderInstance()
    if (leader && leader !== root) {
      try {
        if (typeof leader.refreshNow === "function") {
          leader.refreshNow()
          return
        }
      } catch (e) {
        // The leader was destroyed; the heartbeat re-elects shortly.
      }
    }
    if (Model.pollClaim(root, Date.now())) {
      root.pollLeader = true
      root.requestFetch("manual")
    }
  }

  function applyOutput(raw) {
    var parsed = Model.parseResult(raw)
    if (parsed === null) {
      if (String(raw || "").trim() !== "") {
        root.errorText = "Unreadable output from the Grok log reader"
        root.lastErrorMessage = root.errorText
      }
      return
    }
    root.gotOutput = true
    var now = Date.now()
    if (!parsed.ok) {
      root.handleFailure(parsed.error, now)
      return
    }
    root.handleSuccess(parsed.report, now)
  }

  function lastStderrLine() {
    var lines = stderrText.split("\n")
    for (var i = lines.length - 1; i >= 0; i--) {
      var line = String(lines[i] || "").trim()
      if (line !== "") return line.slice(0, 240)
    }
    return ""
  }

  Process {
    id: fetchProc
    running: false

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyOutput(text)
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.stderrText = String(text || "").trim()
    }

    onExited: function(exitCode, exitStatus) {
      if (root.gotOutput) return
      var line = root.lastStderrLine()
      var message = line !== ""
        ? line
        : (exitCode === 127
          ? "node not found; set the Node executable in the widget settings"
          : exitCode === 0
            ? (root.lastErrorMessage !== "" ? root.lastErrorMessage : "the Grok log reader returned no data")
            : "Grok log reader failed (exit " + exitCode + ")")
      root.handleFailure(message, Date.now())
    }
  }

  // Read the cache synchronously so the first frame already has data, then wait
  // out whatever remains of the interval instead of reading on every restart.
  FileView {
    id: cacheFile
    path: root.cachePath
    blockLoading: true
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: if (root.startupDone) root.loadCache(text())
    onLoadFailed: if (root.startupDone) root.loadCache("")
  }

  Process {
    id: cacheDirProc
    command: ["install", "-d", "-m", "700", root.cacheDir]
    running: true
  }

  Component.onCompleted: {
    root.loadCache(cacheFile.loaded ? cacheFile.text() : "")
    root.cacheLoadAttempted = true
    root.startupDone = true
    Qt.callLater(function() {
      root.settingsReady = true
      if (root.pollLeader) root.startPolling()
    })
  }

  Component.onDestruction: Model.pollRelease(root)

  // One-shot, re-armed after every result. Its interval is derived from the
  // cache timestamps, so a restart inherits the previous process's schedule.
  Timer {
    id: poll
    repeat: false
    running: root.pollLeader
    triggeredOnStart: false
    onTriggered: root.requestFetch("auto")
  }

  // A manual refresh inside the cooldown runs once the floor opens.
  Timer {
    id: manualCatchup
    repeat: false
    onTriggered: root.requestFetch("manual")
  }

  // Leadership heartbeat and result fan-out across monitors.
  Timer {
    id: pollCoordination
    interval: 5000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: {
      var wasLeader = root.pollLeader
      root.pollLeader = Model.pollClaim(root, Date.now())
      if (root.pollLeader && !wasLeader) root.startPolling()
      if (root.pollLeader || wasLeader) return
      var shared = Model.pollConsume(root)
      if (shared && shared.seq > root.consumedSeq) {
        root.consumedSeq = shared.seq
        root.applyResult(shared)
      }
    }
  }

  // Keeps "Resets in" and the snapshot age honest while the popup is open.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  onOpenedChanged: if (opened) {
    nowMs = Date.now()
    // A fresh cache is enough for the popup; only read again when the interval
    // has actually elapsed. The leader's scheduled timer usually does this.
    if (root.pollLeader) {
      if (!root.hasData && !fetchProc.running) root.requestFetch("auto")
      else if (root.lastFetchMs > 0 && Date.now() - root.lastFetchMs > root.refreshIntervalSec * 1000) root.requestFetch("auto")
    }
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function openGrok() {
    Qt.openUrlExternally("https://grok.com/")
  }

  function handleClick(buttonCode) {
    if (buttonCode === Qt.MiddleButton) root.refreshNow()
    else if (buttonCode === Qt.RightButton) {
      if (rightClickCommand !== "" && root.bar) root.bar.run(rightClickCommand)
      else root.openGrok()
    } else {
      root.toggle()
    }
  }

  ShellIpc {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    function text(): string { return root.compactText }
  }

  // -------------------------------------------------------------------- bar

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    dimmed: !root.hasData
    active: root.alarming
    tooltipText: root.tooltipText
    fixedWidth: root.vertical ? -1 : Math.ceil(content.implicitWidth + button.scaledHorizontalMargin * 2)
    fixedHeight: root.vertical ? Math.ceil(content.implicitHeight + button.scaledVerticalPadding * 2) : -1

    onPressed: function(buttonCode) { root.handleClick(buttonCode) }

    Grid {
      id: content
      anchors.centerIn: parent
      columns: root.vertical ? 1 : 2
      rows: root.vertical ? 2 : 1
      columnSpacing: Style.space(5)
      rowSpacing: Style.space(3)
      verticalItemAlignment: Grid.AlignVCenter
      horizontalItemAlignment: Grid.AlignHCenter

      GrokMark {
        markSize: Style.bar.iconFont + 3
        color: root.alarming ? root.stateColor("critical") : root.foreground
      }

      Text {
        textFormat: Text.PlainText
        visible: root.barStyle === "text" && root.compactText !== ""
        text: root.compactText
        color: root.highest ? root.stateColor(root.highest.state) : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        renderType: Text.NativeRendering
      }

      Column {
        visible: root.barStyle === "bars" && root.barWindows.length > 0
        spacing: Style.space(2)

        Repeater {
          model: root.barStyle === "bars" ? root.barWindows : []

          Item {
            id: miniMeter
            required property var modelData
            width: Style.space(20)
            height: Style.space(3)

            Rectangle {
              anchors.fill: parent
              radius: height / 2
              color: root.track
            }

            Rectangle {
              width: Math.max(height, parent.width * miniMeter.modelData.percent / 100)
              height: parent.height
              radius: height / 2
              color: root.stateColor(miniMeter.modelData.state)

              Behavior on width {
                NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic }
              }
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------------ popup

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTextKey: function(text) {
        if (text === "r") root.refreshNow()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: panelColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        Column {
          id: panelColumn
          width: panelFlick.width
          spacing: Style.space(14)

          PanelHero {
            width: parent.width
            title: "Grok"
            meta: root.heroMeta
            detail: root.heroDetail
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              GrokMark {
                markSize: Style.font.display
                color: root.alarming ? root.stateColor("critical") : root.foreground
              }
            }

            trailingControl: Component {
              Row {
                spacing: Style.spacing.sm

                PanelActionButton {
                  iconText: "󰏌"
                  tooltipText: "Open grok.com"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.openGrok()
                }

                PanelActionButton {
                  iconText: "󰑐"
                  tooltipText: root.busy ? "Reading…" : "Refresh (r)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: !root.busy
                  onClicked: root.refreshNow()
                }
              }
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

          // Empty / error state. The copy points at the fix rather than just
          // saying the read failed.
          Column {
            visible: !root.hasData
            width: parent.width
            spacing: Style.space(4)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.errorText !== "" ? "No usage snapshot" : "Reading the Grok snapshot"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.errorText !== ""
                ? root.errorText
                : "Looking for the billing line in ~/.grok/logs/unified.jsonl."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              visible: root.errorText !== ""
              width: parent.width
              text: "Run `grok` once and open `/usage`; Grok writes the plan snapshot locally. The widget reads that file only — no API key, network request, or auth token."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Repeater {
            model: root.hasData ? root.allWindows : []

            LimitRow {
              required property var modelData
              width: panelColumn.width
              window: modelData
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.bot !== null && root.showBot
            width: parent.width
            text: "Grok Bot's weekly limit comes from the local Grok Bot app cache; open Grok Bot to refresh it."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // On-demand and prepaid amounts are shown only when the account
          // actually reports one; the units are left as Grok reports them.
          Column {
            visible: root.hasBilling
            width: parent.width
            spacing: Style.space(5)

            PanelSeparator {
              foreground: root.foreground
            }

            PanelSectionHeader {
              foreground: root.foreground
              fontFamily: root.fontFamily
              text: "Billing"
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: root.onDemand !== null && (root.onDemand.cap > 0 || root.onDemand.used > 0)
              text: {
                if (!root.onDemand) return ""
                return "On-demand: " + Model.formatAmount(root.onDemand.used)
                  + " used · " + Model.formatAmount(root.onDemand.cap) + " cap"
              }
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: root.onDemand !== null && root.onDemand.prepaid > 0
              text: root.onDemand ? "Prepaid balance: " + Model.formatAmount(root.onDemand.prepaid) : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }
          }

          Column {
            visible: root.hasLocal
            width: parent.width
            spacing: Style.space(5)

            PanelSeparator {
              foreground: root.foreground
            }

            PanelSectionHeader {
              foreground: root.foreground
              fontFamily: root.fontFamily
              text: root.report
                ? "Local activity · " + Model.periodLocal(root.report.period)
                : "Local activity"
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: {
                if (!root.local) return ""
                var sessions = root.local.sessions === 1 ? "1 session" : root.local.sessions + " sessions"
                var turns = root.local.turns === 1 ? "1 turn" : root.local.turns + " turns"
                return turns + " · " + sessions + " · " + Model.formatCost(root.local.costUsd)
              }
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: {
                if (!root.local) return ""
                return Model.formatCount(root.local.input) + " input · "
                  + Model.formatCount(root.local.output) + " output · "
                  + Model.formatCount(root.local.cached) + " cached"
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "From Grok's local session ledger; whole turns since the period started."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Column {
            visible: root.showMonthSection
            width: parent.width
            spacing: Style.space(5)

            PanelSeparator {
              foreground: root.foreground
            }

            PanelSectionHeader {
              foreground: root.foreground
              fontFamily: root.fontFamily
              text: "Local activity · 30 days"
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: {
                if (!root.localMonth) return ""
                var sessions = root.localMonth.sessions === 1 ? "1 session" : root.localMonth.sessions + " sessions"
                var turns = root.localMonth.turns === 1 ? "1 turn" : root.localMonth.turns + " turns"
                return turns + " · " + sessions + " · " + Model.formatCost(root.localMonth.costUsd)
              }
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: {
                if (!root.localMonth) return ""
                return Model.formatCount(root.localMonth.input) + " input · "
                  + Model.formatCount(root.localMonth.output) + " output · "
                  + Model.formatCount(root.localMonth.cached) + " cached"
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Local session ledger for the last 30 days; Grok's plan allowance itself is weekly."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.footerText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // One limit window: label and percentage, meter, reset countdown.
  component LimitRow: Column {
    id: limitRow
    property var window: null

    readonly property color valueColor: root.stateColor(window ? window.state : "normal")
    readonly property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    width: parent ? parent.width : implicitWidth
    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(limitLabel.implicitHeight, limitValue.implicitHeight)

      Text {
        id: limitLabel
        textFormat: Text.PlainText
        text: limitRow.window ? limitRow.window.detail : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.right: limitValue.left
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: limitValue
        textFormat: Text.PlainText
        text: limitRow.window
          ? (limitRow.window.expired ? "—" : Model.percentText(limitRow.window.percent))
          : "—"
        color: limitRow.valueColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Item {
      width: parent.width
      implicitHeight: limitRow.thickness

      Rectangle {
        id: meterTrack
        anchors.fill: parent
        radius: height / 2
        color: root.track
      }

      Rectangle {
        anchors.left: meterTrack.left
        anchors.verticalCenter: meterTrack.verticalCenter
        height: meterTrack.height
        radius: meterTrack.radius
        width: Math.max(height, meterTrack.width * (limitRow.window ? limitRow.window.percent : 0) / 100)
        color: limitRow.valueColor

        Behavior on width {
          NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic }
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: {
        if (!limitRow.window) return ""
        if (limitRow.window.expired) {
          var noun = root.report ? Model.periodNoun(root.report.period) : "period"
          return "Period ended; open Grok to read the new " + noun
        }
        var reset = Model.resetText(limitRow.window.resetsAt, root.nowMs)
        var clock = root.clockAt(limitRow.window.resetsAt)
        var when = clock !== "" ? reset + " (" + clock + ")" : reset
        if (limitRow.window.stale) when += " · cached"
        return when
      }
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }
}
