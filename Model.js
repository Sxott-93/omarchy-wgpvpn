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
