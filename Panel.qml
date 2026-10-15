import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// wg-VPN control panel: discovers WireGuard/AmneziaWG configs, lists the
// configured VPNs with per-VPN route management, and toggles each interface
// up/down. Privileged work goes through pkexec'd vpnhelper; unprivileged
// state goes through vpnstore.
//
// Single-file bar-widget pattern (like omarchy.audio): this Panel base item
// is the bar slot's content — BarIconButton renders in the bar, KeyboardPanel
// is the popout. The bar slot injects `bar`; open/close/toggle come from the
// base (panelController) with the overrides below adding VPN bookkeeping.
Panel {
  id: root
  moduleName: "sxott.wgpvpn"
  ipcTarget: "sxott.wgpvpn.panel"

  readonly property string home: Quickshell.env("HOME") || "/"
  readonly property string storeDir: home + "/.config/omarchy/plugins/sxott.wgpvpn"
  readonly property string dataDir: (Quickshell.env("XDG_DATA_HOME") || home + "/.local/share") + "/omarchy-wgpvpn"
  readonly property string vpnsJson: root.dataDir + "/vpns.json"

  property var vpns: []
  property var found: []
  // Installed *-quick binaries, refreshed with every list/scan (first open
  // and the scan-for-configs button): { "awg-quick": path|null, ... }.
  property var tools: ({})
  property bool everScanned: false
  property var linkStatus: ({})
  // { name: { addr } } from `ip -j addr show` (link show omits it on AWG).
  property var addrStatus: ({})
  property string busyName: ""
  property bool busyOn: false
  property string statusLine: ""
  property bool statusIsError: false
  property int expanded: -1
  property bool routeBypass: false
  property int removeTarget: -1
  property bool removePending: false
  property var _pendingRouteField: null
  // True while a route CIDR field has keyboard focus: the PanelKeyCatcher is
  // blocked so typing (and Enter = add route) reaches the field.
  property bool _fieldEditing: false

  // Icon tint: any configured VPN up. Derived from the polled link status,
  // so the 30 s bar poll and the 5 s panel poll both keep it fresh.
  readonly property bool anyUp: {
    var list = Array.isArray(vpns) ? vpns : []
    for (var i = 0; i < list.length; i++)
      if (list[i] && Model.isVpnUp(linkStatus, String(list[i].name || "")))
        return true
    return false
  }

  // Device a generic (internet) packet exits through, per `ip route get`
  // (honors policy routing). Drives the full-tunnel / LAN-bypass badge.
  property string tunnelDev: ""
  // Per-interface traffic rates, bytes/s: { name: { down, up} }.
  property var netRates: ({})
  // Previous net-stat sample, for the delta.
  property var _prevNet: ({})

  // The bar slot sizes itself from this item's implicit size; the anchored
  // button alone contributes nothing, so take the button's (same as audio).
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ------------------------------------------------------------ lifecycle

  Component.onCompleted: {
    // The bar tint needs the VPN list on a cold shell, before the panel is
    // ever opened; the list handler kicks off the first link poll.
    root.runStore(["list"], "list")
  }

  function open(payloadJson) {
    root.controller.show()
    root.refreshStore(["list"], "list")
  }

  function close() {
    root.controller.hide()
    if (storeProc.running) { storeProc.expectedStop = true; storeProc.running = false }
    if (vpnProc.running) { vpnProc.expectedStop = true; vpnProc.running = false }
    if (linkProc.running) { linkProc.expectedStop = true; linkProc.running = false }
    if (addrProc.running) { addrProc.expectedStop = true; addrProc.running = false }
    if (routeProc.running) { routeProc.expectedStop = true; routeProc.running = false }
    if (netProc.running) { netProc.expectedStop = true; netProc.running = false }
    root.statusLine = ""
    root.statusIsError = false
  }

  // ------------------------------------------------------------ store ops

  function runStore(args, op) {
    storeProc.expectedStop = false
    storeProc.op = op
    storeProc.command = [root.storeDir + "/vpnstore"].concat(args)
    storeProc.running = true
  }

  function refreshStore(args, op) {
    if (storeProc.running) {
      storeProc.expectedStop = true
      storeProc.running = false
      Qt.callLater(function() { root.runStore(args, op) })
      return
    }
    root.runStore(args, op)
  }

  function scanConfigs() {
    root.refreshStore(["scan"], "scan")
  }

  function addFound(index) {
    var item = Array.isArray(root.found) ? root.found[index] : null
    if (!item) return
    root.refreshStore(["add", item.path], "add")
  }

  function requestRemove(index) {
    var vpn = Array.isArray(root.vpns) ? root.vpns[index] : null
    if (!vpn) return
    root.removeTarget = index
    root.removePending = true
  }

  function confirmRemove() {
    root.removePending = false
    var vpn = Array.isArray(root.vpns) ? root.vpns[root.removeTarget] : null
    root.removeTarget = -1
    if (!vpn) return
    root.refreshStore(["remove", vpn.name], "remove")
  }

  function addRoute(vpnIndex, field) {
    var vpn = Array.isArray(root.vpns) ? root.vpns[vpnIndex] : null
    if (!vpn) return
    var cidr = field && field.text ? String(field.text).trim() : ""
    if (cidr === "") return
    root._pendingRouteField = field || null
    root.refreshStore(["add-route", vpn.name, cidr, root.routeBypass ? "1" : "0"],
                      "route:add:" + vpnIndex)
  }

  function removeRoute(vpnIndex, routeIndex) {
    var vpn = Array.isArray(root.vpns) ? root.vpns[vpnIndex] : null
    if (!vpn || !Array.isArray(vpn.routes)) return
    var route = vpn.routes[routeIndex]
    if (!route) return
    root.refreshStore(["remove-route", vpn.name, route.cidr], "route:remove:" + vpnIndex)
  }

  // ------------------------------------------------------------ vpn ops

  function toggleVpn(index) {
    var vpn = Array.isArray(root.vpns) ? root.vpns[index] : null
    if (!vpn || root.busyName !== "") return
    var quick = Model.quickFor(vpn, root.tools)
    if (quick === "") {
      root.statusIsError = true
      root.statusLine = vpn.name + ": " + (vpn.kind === "amneziawg"
        ? "needs amneziawg-tools (awg-quick) installed"
        : "needs wireguard-tools or amneziawg-tools installed")
      return
    }
    var wantOn = !Model.isVpnUp(root.linkStatus, vpn.name)
    root.busyName = vpn.name
    root.busyOn = wantOn
    root.statusLine = ""
    root.statusIsError = false
    vpnProc.expectedStop = false
    vpnProc.name = vpn.name
    vpnProc.wantOn = wantOn
    vpnProc.command = ["pkexec", root.storeDir + "/vpnhelper",
                       wantOn ? "up" : "down", root.vpnsJson, vpn.name, quick]
    vpnProc.running = true
  }

  // ------------------------------------------------------------ links

  function pollLinks() {
    if (linkProc.running) return
    linkProc.expectedStop = false
    linkProc.command = ["/usr/bin/ip", "-j", "link", "show"]
    linkProc.running = true
  }

  function pollRoutes() {
    if (routeProc.running) return
    routeProc.expectedStop = false
    routeProc.command = ["/usr/bin/ip", "-j", "route", "get", "8.8.8.8"]
    routeProc.running = true
  }

  function pollAddrs() {
    if (addrProc.running) return
    addrProc.expectedStop = false
    addrProc.command = ["/usr/bin/ip", "-j", "addr", "show"]
    addrProc.running = true
  }

  function pollStatus() {
    root.pollLinks()
    root.pollRoutes()
    root.pollAddrs()
  }

  // Sample /sys/class/net/<if>/statistics for every up VPN in one cat; the
  // rate is the delta against the previous sample.
  function pollNetStats() {
    var names = []
    var list = Array.isArray(vpns) ? vpns : []
    for (var i = 0; i < list.length; i++) {
      if (list[i] && Model.isVpnUp(linkStatus, String(list[i].name || "")))
        names.push(String(list[i].name))
    }
    if (names.length === 0) {
      if (Object.keys(root._prevNet).length > 0) {
        root._prevNet = ({})
        root.netRates = ({})
      }
      return
    }
    if (netProc.running) return
    netProc.expectedStop = false
    netProc.names = names.join(" ")
    var files = []
    for (var n = 0; n < names.length; n++) {
      files.push("/sys/class/net/" + names[n] + "/statistics/rx_bytes")
      files.push("/sys/class/net/" + names[n] + "/statistics/tx_bytes")
    }
    netProc.command = ["/bin/cat"].concat(files)
    netProc.running = true
  }

  // ------------------------------------------------------------ processes

  Process {
    id: storeProc
    property bool expectedStop: false
    property string op: ""
    stdout: StdioCollector { id: storeOut; waitForEnd: true }
    onExited: function(code) {
      if (storeProc.expectedStop) { storeProc.expectedStop = false; return }
      var op = String(storeProc.op || "")
      storeProc.op = ""
      var parsed = Model.safeParse(storeOut.text, null)
      var error = Model.storeError(parsed)
      if (error !== "") {
        root.statusIsError = true
        root.statusLine = error
        return
      }
      if (op === "list") {
        root.vpns = parsed && Array.isArray(parsed.vpns) ? parsed.vpns : []
        root.tools = parsed && parsed.tools ? parsed.tools : ({})
        root.pollLinks()
        // First run, nothing configured: look for configs on disk.
        if (root.vpns.length === 0 && !root.everScanned)
          root.runStore(["scan"], "scan")
      } else if (op === "scan") {
        root.found = parsed && Array.isArray(parsed.found) ? parsed.found : []
        root.tools = parsed && parsed.tools ? parsed.tools : ({})
        root.everScanned = true
      } else {
        root.vpns = parsed && Array.isArray(parsed.vpns) ? parsed.vpns : []
        root.tools = parsed && parsed.tools ? parsed.tools : ({})
        if (op.indexOf("route:add") === 0) {
          root.routeBypass = false
          if (root._pendingRouteField) root._pendingRouteField.text = ""
          root._pendingRouteField = null
        }
        if (op === "add" || op === "remove")
          root.runStore(["scan"], "scan")
        root.pollLinks()
      }
    }
  }

  Process {
    id: vpnProc
    property bool expectedStop: false
    property string name: ""
    property bool wantOn: false
    stdout: StdioCollector { id: vpnOut; waitForEnd: true }
    stderr: StdioCollector { id: vpnErr; waitForEnd: true }
    onExited: function(code) {
      if (vpnProc.expectedStop) { vpnProc.expectedStop = false; return }
      root.busyName = ""
      if (code === 0) {
        var out = String(vpnOut.text || "").trim()
        root.statusIsError = false
        root.statusLine = out !== ""
          ? out
          : (vpnProc.wantOn ? vpnProc.name + " is up" : vpnProc.name + " is down")
      } else {
        var detail = Model.shortError(vpnErr.text || vpnOut.text)
        root.statusIsError = true
        root.statusLine = detail !== ""
          ? detail
          : "operation failed (auth canceled?)"
      }
      root.pollLinks()
    }
  }

  Process {
    id: linkProc
    property bool expectedStop: false
    stdout: StdioCollector { id: linkOut; waitForEnd: true }
    onExited: {
      if (linkProc.expectedStop) { linkProc.expectedStop = false; return }
      root.linkStatus = Model.parseLinkStatus(linkOut.text, Model.vpnNames(root.vpns))
    }
  }

  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: root.pollStatus()
  }

  Process {
    id: routeProc
    property bool expectedStop: false
    stdout: StdioCollector { id: routeOut; waitForEnd: true }
    onExited: {
      if (routeProc.expectedStop) { routeProc.expectedStop = false; return }
      root.tunnelDev = Model.tunnelDev(routeOut.text)
    }
  }

  Process {
    id: addrProc
    property bool expectedStop: false
    stdout: StdioCollector { id: addrOut; waitForEnd: true }
    onExited: {
      if (addrProc.expectedStop) { addrProc.expectedStop = false; return }
      root.addrStatus = Model.parseAddrStatus(addrOut.text, Model.vpnNames(root.vpns))
    }
  }

  Process {
    id: netProc
    property bool expectedStop: false
    property string names: ""
    stdout: StdioCollector { id: netOut; waitForEnd: true }
    onExited: function(code) {
      if (netProc.expectedStop) { netProc.expectedStop = false; return }
      var names = String(netProc.names).split(" ")
      var lines = String(netOut.text || "").trim().split(/\r?\n/)
      if (code !== 0 || lines.length !== names.length * 2) return
      var now = new Date().getTime()
      var cur = ({})
      for (var i = 0; i < names.length; i++) {
        var rx = parseFloat(lines[i * 2])
        var tx = parseFloat(lines[i * 2 + 1])
        if (isNaN(rx) || isNaN(tx)) return
        cur[names[i]] = { rx: rx, tx: tx, t: now }
      }
      var prev = root._prevNet
      var rates = ({})
      for (var n in cur) {
        var p = prev[n]
        if (!p || !p.t) continue
        var dt = (now - p.t) / 1000
        if (!(dt > 0)) continue
        var down = Math.max(0, cur[n].rx - p.rx) / dt
        var up = Math.max(0, cur[n].tx - p.tx) / dt
        rates[n] = { down: down, up: up }
      }
      root._prevNet = cur
      root.netRates = rates
    }
  }

  Timer {
    interval: 2000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.pollNetStats()
  }

  Timer {
    interval: 30000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.pollLinks()
  }

  // ------------------------------------------------------------ the button

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.anyUp ? "VPN: up — click to manage" : "VPN: click to manage"
    iconComponent: Component {
      KeyIcon {
        width: Style.space(16)
        height: Style.space(16)
        color: root.anyUp ? Color.accent : (root.bar ? root.bar.foreground : "white")

        Behavior on color {
          ColorAnimation { duration: 160 }
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) {
        // Refresh the link status immediately instead of waiting for the
        // next 30 s tick.
        root.pollStatus()
      } else {
        root.toggle()
      }
    }
  }

  // ------------------------------------------------------------- the popout

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root._fieldEditing
      // While the remove dialog is open the dialog owns the keys: Escape
      // cancels it, arrows/Tab move between its buttons, Enter activates.
      onCloseRequested: {
        if (root.removePending) { root.removePending = false; return }
        root.close()
      }
      onTabRequested: function(direction) {
        if (root.removePending) {
          removeDialog.selectedIndex = removeDialog.selectedIndex === 0 ? 1 : 0
          return
        }
        root.switchPanel(direction)
      }
      onReturnRequested: {
        if (root.removePending) {
          if (removeDialog.selectedIndex === 1) root.confirmRemove()
          else root.removePending = false
        }
      }
      onActivateRequested: {
        if (root.removePending) {
          if (removeDialog.selectedIndex === 1) root.confirmRemove()
          else root.removePending = false
        }
      }

      Flickable {
        id: scroller
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: content
          // Held a hair inside the scrolling viewport: a row whose border
          // lands exactly on the clip boundary loses that edge.
          x: Style.space(2)
          width: parent.width - Style.space(4)
          spacing: Style.space(12)

          // ---- header
          RowLayout {
            layoutDirection: Qt.LeftToRight
            spacing: Style.space(8)
            width: parent.width

            KeyIcon {
              width: Style.space(14)
              height: Style.space(14)
              color: Color.accent
              Layout.alignment: Qt.AlignVCenter
            }

            Text {
              text: "VPN"
              font.pixelSize: Style.font.title
              font.weight: Font.DemiBold
              color: Color.foreground
              Layout.alignment: Qt.AlignVCenter
            }

            Item { Layout.fillWidth: true }

            PanelActionButton {
              iconText: "↻"
              tooltipText: "Scan for config files"
              Layout.alignment: Qt.AlignVCenter
              onClicked: root.scanConfigs()
            }
          }

          PanelSeparator { width: parent.width }

          // ---- vpn list
          Repeater {
            model: root.vpns

            ColumnLayout {
              id: vpnBlock
              required property int index
              readonly property var vpn: Array.isArray(root.vpns) ? root.vpns[index] : null
              readonly property bool up: vpn ? Model.isVpnUp(root.linkStatus, vpn.name) : false
              readonly property string addr: vpn ? Model.vpnAddr(root.addrStatus, vpn.name) : ""
              // Holds the machine's default route (full tunnel) vs LAN-out (bypass).
              readonly property bool fullTunnel: up && vpn && root.tunnelDev === vpn.name
              readonly property var showRouteBadge: up && root.tunnelDev !== ""
              // "↓ 1.4 MB/s ↑ 210 KB/s" from the 2 s traffic sampling.
              readonly property string rateLine: {
                var r = vpn && root.netRates ? root.netRates[vpn.name] : null
                if (!r) return ""
                return "↓ " + Model.formatRate(r.down) + "   ↑ " + Model.formatRate(r.up)
              }
              readonly property bool busy: vpn ? root.busyName === vpn.name : false
              readonly property bool expanded: root.expanded === index

              width: parent.width
              spacing: Style.space(6)

              // row
              RowLayout {
                layoutDirection: Qt.LeftToRight
                spacing: Style.space(8)
                width: parent.width

                Rectangle {
                  id: statusDot
                  width: Style.space(6)
                  height: Style.space(6)
                  radius: Style.space(3)
                  color: vpnBlock.busy ? Color.urgent
                        : (vpnBlock.up ? Color.accent : Util.alpha(Color.foreground, 0.3))
                  Layout.alignment: Qt.AlignVCenter

                  // Busy marker inside the dot: the dot is the only
                  // unmanaged parent here, so anchors are safe.
                  Rectangle {
                    id: busyDot
                    anchors.centerIn: parent
                    width: Style.space(3)
                    height: Style.space(3)
                    radius: Style.space(1.5)
                    visible: vpnBlock.busy
                    color: Color.background
                    OpacityAnimator {
                      target: busyDot
                      from: 0.2
                      to: 1.0
                      duration: 500
                      loops: Animation.Infinite
                      running: vpnBlock.busy
                    }
                  }
                }

                ColumnLayout {
                  spacing: 1
                  Layout.alignment: Qt.AlignVCenter

                  RowLayout {
                    spacing: Style.space(6)
                    Text {
                      text: vpnBlock.vpn ? vpnBlock.vpn.name : ""
                      font.pixelSize: Style.font.subtitle
                      font.weight: Font.Medium
                      color: Color.foreground
                    }
                    Rectangle {
                      visible: vpnBlock.vpn && (vpnBlock.vpn.kind === "amneziawg" || vpnBlock.vpn.kind === "wireguard")
                      width: Style.space(20)
                      height: Style.space(11)
                      radius: Style.space(3)
                      color: Util.alpha(vpnBlock.vpn && vpnBlock.vpn.kind === "amneziawg" ? Color.accent : Color.foreground, 0.16)
                      Text {
                        anchors.centerIn: parent
                        text: vpnBlock.vpn && vpnBlock.vpn.kind === "amneziawg" ? "AWG" : "WG"
                        font.pixelSize: Style.font.caption
                        color: Color.foreground
                      }
                    }

                    // Where this up VPN's traffic is going: its interface holds
                    // the default route (full tunnel) or the LAN NIC does.
                    Rectangle {
                      visible: vpnBlock.showRouteBadge
                      height: Style.space(11)
                      width: routeBadgeText.implicitWidth + Style.space(12)
                      radius: Style.space(3)
                      color: vpnBlock.fullTunnel
                        ? Util.alpha(Color.accent, 0.16)
                        : Util.alpha(Color.foreground, 0.1)
                      Layout.alignment: Qt.AlignVCenter
                      Text {
                        id: routeBadgeText
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: Style.space(6)
                        text: vpnBlock.fullTunnel ? "full tunnel" : "LAN bypass"
                        font.pixelSize: Style.font.caption
                        color: vpnBlock.fullTunnel ? Color.accent : Util.alpha(Color.foreground, 0.7)
                      }
                    }
                  }

                  Text {
                    visible: vpnBlock.addr !== ""
                    text: vpnBlock.addr
                    font.pixelSize: Style.font.caption
                    color: Util.alpha(Color.foreground, 0.55)
                  }

                  Text {
                    visible: vpnBlock.up && vpnBlock.rateLine !== ""
                    text: vpnBlock.rateLine
                    font.pixelSize: Style.font.caption
                    color: Util.alpha(Color.foreground, 0.55)
                  }

                  // No installed binary can drive this VPN: say so on the row.
                  Text {
                    visible: vpnBlock.vpn && Model.quickFor(vpnBlock.vpn, root.tools) === ""
                    text: vpnBlock.vpn && vpnBlock.vpn.kind === "amneziawg"
                      ? "needs amneziawg-tools (awg-quick)"
                      : "needs wireguard-tools or amneziawg-tools"
                    font.pixelSize: Style.font.caption
                    color: Util.alpha(Color.urgent, 0.9)
                  }
                }

                Item { Layout.fillWidth: true }

                // State switch. The theme's normal chrome is a 4% fill —
                // invisible on the panel background — so the states carry
                // explicit colors: solid accent track when up, muted when
                // down. (Checked follows the optimistic busy value, like the
                // first-party ToggleSwitch would.)
                Rectangle {
                  id: stateSwitch
                  width: Style.space(30)
                  height: Style.space(16)
                  radius: Style.space(8)
                  color: vpnBlock.busy
                    ? Util.alpha(Color.urgent, 0.3)
                    : (vpnBlock.busyOn || (!vpnBlock.busy && vpnBlock.up))
                      ? Util.alpha(Color.accent, 0.9)
                      : Util.alpha(Color.foreground, 0.1)
                  border.width: 1
                  border.color: vpnBlock.busy
                    ? Util.alpha(Color.urgent, 0.7)
                    : (vpnBlock.busyOn || (!vpnBlock.busy && vpnBlock.up))
                      ? Color.accent
                      : Util.alpha(Color.foreground, 0.3)
                  Layout.alignment: Qt.AlignVCenter

                  Rectangle {
                    id: stateKnob
                    width: Style.space(10)
                    height: Style.space(10)
                    radius: Style.space(5)
                    x: stateSwitch.width - width - Style.space(3)
                    anchors.verticalCenter: parent.verticalCenter
                    color: (vpnBlock.busyOn || (!vpnBlock.busy && vpnBlock.up))
                      ? Color.background
                      : Util.alpha(Color.foreground, 0.55)
                    Behavior on x {
                      NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                    }
                    Behavior on color {
                      ColorAnimation { duration: 120 }
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    enabled: !vpnBlock.busy
                            && Model.quickFor(vpnBlock.vpn, root.tools) !== ""
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleVpn(vpnBlock.index)
                  }
                }

                // Expand button: right of the switch, sized to match the
                // toggle. Clicking it (or the row) opens the route editor in
                // the expanded detail.
                Text {
                  text: vpnBlock.expanded ? "▾" : "▸"
                  font.pixelSize: Style.font.heading
                  color: Util.alpha(Color.foreground, 0.85)
                  Layout.alignment: Qt.AlignVCenter

                  MouseArea {
                    id: chevronMouse
                    anchors.fill: parent
                    anchors.margins: -Style.space(4)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.expanded = vpnBlock.expanded ? -1 : index
                  }

                  PanelToolTip {
                    visible: chevronMouse.containsMouse
                    text: vpnBlock.expanded ? "Collapse routes" : "Manage routes"
                  }
                }

                // Clicking the row toggles the detail; later siblings (dot,
                // text, switch) sit on top and keep their own clicks.
                MouseArea {
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  onClicked: root.expanded = vpnBlock.expanded ? -1 : index
                }
              }

              // ---- expanded detail
              ColumnLayout {
                visible: vpnBlock.expanded
                width: parent.width - Style.space(14)
                Layout.leftMargin: Style.space(14)
                spacing: Style.space(6)

                Text {
                  text: vpnBlock.vpn ? vpnBlock.vpn.path : ""
                  font.pixelSize: Style.font.caption
                  color: Util.alpha(Color.foreground, 0.45)
                  elide: Text.ElideMiddle
                  width: parent.width
                }

                PanelSectionHeader { text: "Routes" }

                Repeater {
                  model: vpnBlock.vpn && Array.isArray(vpnBlock.vpn.routes) ? vpnBlock.vpn.routes : []

                  RowLayout {
                    required property int index
                    readonly property var route: Array.isArray(vpnBlock.vpn.routes) ? vpnBlock.vpn.routes[index] : null
                    spacing: Style.space(8)
                    width: parent.width

                    Text {
                      text: route ? route.cidr : ""
                      font.pixelSize: Style.font.bodySmall
                      color: Color.foreground
                    }

                    Rectangle {
                      visible: route && route.bypass === true
                      width: Style.space(26)
                      height: Style.space(11)
                      radius: Style.space(3)
                      color: Util.alpha(Color.urgent, 0.18)
                      Text {
                        anchors.centerIn: parent
                        text: "bypass"
                        font.pixelSize: Style.font.caption
                        color: Color.foreground
                      }
                    }

                    Item { Layout.fillWidth: true }

                    PanelActionButton {
                      iconText: "×"
                      tooltipText: "Remove route"
                      onClicked: root.removeRoute(vpnBlock.index, index)
                    }
                  }
                }

                // add route row
                RowLayout {
                  spacing: Style.space(8)
                  width: parent.width

                  TextField {
                    id: routeField
                    placeholderText: "10.0.0.0/8"
                    Layout.fillWidth: true
                    font.pixelSize: Style.font.bodySmall
                    verticalPadding: Style.space(4)
                    onFocusChanged: root._fieldEditing = focus
                    onAccepted: root.addRoute(vpnBlock.index, routeField)
                  }

                  RowLayout {
                    spacing: Style.space(4)
                    Text {
                      text: "bypass"
                      font.pixelSize: Style.font.bodySmall
                      color: Util.alpha(Color.foreground, 0.7)
                    }
                    ToggleSwitch {
                      checked: root.routeBypass
                      onToggled: root.routeBypass = !root.routeBypass
                    }
                  }

                  PanelActionButton {
                    iconText: "＋"
                    tooltipText: "Add route"
                    onClicked: root.addRoute(vpnBlock.index, routeField)
                  }
                }

                RowLayout {
                  width: parent.width
                  Item { Layout.fillWidth: true }
                  Button {
                    text: "Remove VPN"
                    onClicked: root.requestRemove(vpnBlock.index)
                  }
                }
              }

              PanelSeparator {
                visible: vpnBlock.index < root.vpns.length - 1
                width: parent.width
              }
            }
          }

          // ---- empty state / first run
          ColumnLayout {
            visible: root.vpns.length === 0
            width: parent.width
            spacing: Style.space(8)

            Text {
              text: root.everScanned
                ? "No VPNs configured. Nothing found on disk."
                : "No VPNs configured yet. The scan looks in ~/.config/amnezia, ~/.config/wireguard, /etc/amnezia and /etc/wireguard."
              font.pixelSize: Style.font.bodySmall
              color: Util.alpha(Color.foreground, 0.6)
              wrapMode: Text.WordWrap
              width: parent.width
            }

            RowLayout {
              spacing: Style.space(8)
              Button {
                text: "Scan for configs"
                onClicked: root.scanConfigs()
              }
            }
          }

          // ---- scan results
          ColumnLayout {
            visible: root.found.length > 0 && (root.vpns.length > 0 || root.everScanned)
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader { text: "Found on disk" }

            Repeater {
              model: root.found

              RowLayout {
                required property int index
                readonly property var item: Array.isArray(root.found) ? root.found[index] : null
                spacing: Style.space(8)
                width: parent.width

                Text {
                  text: item ? item.name : ""
                  font.pixelSize: Style.font.bodySmall
                  color: Color.foreground
                  Layout.fillWidth: true
                  elide: Text.ElideMiddle
                }

                Text {
                  visible: item && !item.configured
                  text: item && item.kind === "amneziawg" ? "AWG" : "WG"
                  font.pixelSize: Style.font.caption
                  color: Util.alpha(Color.foreground, 0.5)
                }

                Text {
                  visible: item && item.configured
                  text: "configured"
                  font.pixelSize: Style.font.caption
                  color: Util.alpha(Color.foreground, 0.4)
                }

                PanelActionButton {
                  visible: item && !item.configured
                  iconText: "＋"
                  tooltipText: "Add " + (item ? item.path : "")
                  onClicked: root.addFound(index)
                }
              }
            }
          }

          // ---- status line
          Text {
            id: statusText
            visible: root.statusLine !== ""
            text: root.statusLine
            font.pixelSize: Style.font.caption
            color: root.statusIsError ? Color.urgent : Color.accent
            wrapMode: Text.WordWrap
            width: parent.width
          }
        }
      }

      // Sits inside the popout so its scrim covers exactly the panel.
      ConfirmDialog {
        id: removeDialog
        anchors.fill: parent
        z: 10
        message: "Remove this VPN from the list? Its routes are not touched while it is down; an interface that is still up stays up until you toggle it off."
        confirmText: "Remove"
        opened: root.removePending
        onConfirmed: root.confirmRemove()
        onCanceled: root.removePending = false
      }
    }
  }
}
