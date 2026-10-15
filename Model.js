// Pure helpers for the wg-VPN panel. No QML imports.

function safeParse(text, fallback) {
  try {
    var parsed = JSON.parse(String(text || ""))
    return parsed === null ? fallback : parsed
  } catch (e) {
    return fallback
  }
}

// `ip -j link show` -> { name: { up, addr } } for the given interface names.
function parseLinkStatus(text, names) {
  var out = ({})
  var links = safeParse(text, [])
  if (!Array.isArray(links)) links = []
  for (var i = 0; i < links.length; i++) {
    var link = links[i] || {}
    var name = String(link.ifname || "")
    var wanted = names.indexOf(name) !== -1
    if (!wanted) continue
    var up = false
    var flags = link.flags || []
    for (var j = 0; j < flags.length; j++)
      if (String(flags[j]).toLowerCase() === "up") { up = true; break }
    var addr = ""
    var infos = link.addr_info || []
    for (var k = 0; k < infos.length; k++)
      if (infos[k] && infos[k].family === "inet") { addr = String(infos[k].local_address || ""); break }
    out[name] = { up: up, addr: addr }
  }
  return out
}

// `ip -j route get 8.8.8.8` -> the device a generic (internet) packet would
// actually exit through, honoring policy routing (which wg-quick/awg-quick
// sets up). ip -j wraps the single result in a one-element list. "" when
// unresolvable.
function tunnelDev(text) {
  var r = safeParse(text, null)
  if (Array.isArray(r) && r.length > 0) r = r[0]
  if (r && r.dev) return String(r.dev)
  return ""
}

// `ip -j addr show` -> { name: { addr } } for the given interface names.
// (Unlike `ip -j link show`, which on some drivers — notably the AmneziaWG
// kernel module — omits addr_info entirely.)
function parseAddrStatus(text, names) {
  var out = ({})
  var addrs = safeParse(text, [])
  if (!Array.isArray(addrs)) addrs = []
  for (var i = 0; i < addrs.length; i++) {
    var a = addrs[i] || {}
    var name = String(a.ifname || "")
    if (names.indexOf(name) === -1) continue
    var infos = a.addr_info || []
    for (var k = 0; k < infos.length; k++) {
      if (infos[k] && infos[k].family === "inet") {
        out[name] = { addr: String(infos[k].local || "") }
        break
      }
    }
  }
  return out
}

// Bytes per second -> "1.4 MB/s" (decimal units, network convention).
function formatRate(bps) {
  var v = Number(bps) || 0
  if (v < 1000) return Math.round(v) + " B/s"
  if (v < 1000000) return (v / 1000).toFixed(1) + " KB/s"
  if (v < 1000000000) return (v / 1000000).toFixed(1) + " MB/s"
  return (v / 1000000000).toFixed(2) + " GB/s"
}

function vpnNames(vpns) {
  var out = []
  var list = Array.isArray(vpns) ? vpns : []
  for (var i = 0; i < list.length; i++)
    if (list[i] && list[i].name) out.push(String(list[i].name))
  return out
}

function isVpnUp(status, name) {
  var entry = status ? status[name] : null
  return entry ? entry.up === true : false
}

// Full path of the *-quick binary that can drive this VPN, or "" when
// nothing installed can. AmneziaWG configs need awg-quick; plain WireGuard
// works with awg-quick (preferred) or wg-quick. `tools` comes from the
// vpnstore list/scan output: { "awg-quick": path|null, "wg-quick": path|null }.
function quickFor(vpn, tools) {
  if (!vpn || !tools) return ""
  var awg = tools["awg-quick"] || ""
  var wg = tools["wg-quick"] || ""
  if (vpn.kind === "amneziawg") return awg
  return awg !== "" ? awg : wg
}

function vpnAddr(status, name) {
  var entry = status ? status[name] : null
  return entry ? String(entry.addr || "") : ""
}

// The last non-empty lines of a process's combined output, trimmed: what the
// status line shows when an operation fails.
function shortError(raw, limit) {
  var max = limit || 300
  var lines = String(raw || "").trim().split(/\r?\n/)
  var kept = []
  for (var i = lines.length - 1; i >= 0 && kept.length < 2; i--)
    if (lines[i].trim() !== "") kept.unshift(lines[i].trim())
  var text = kept.join(" ")
  if (text.length > max) text = text.slice(0, max - 1) + "…"
  return text
}

// {"error": "..."} documents from vpnstore.
function storeError(parsed) {
  if (parsed && parsed.error !== undefined && parsed.error !== null)
    return String(parsed.error)
  return ""
}
