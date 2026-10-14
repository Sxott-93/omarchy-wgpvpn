# sxott.wgpvpn — WireGuard / AmneziaWG control panel

An Omarchy shell plugin: discovers WireGuard and AmneziaWG client configs,
lists the VPNs you configure, toggles each one up/down, and manages per-VPN
extra routes (including LAN bypass routes).

## Layout

```
manifest.json   plugin manifest (bar-widget; Panel.qml is the entry point)
Panel.qml       the whole plugin: qs.Ui Panel base + BarIconButton + KeyboardPanel
KeyIcon.qml     the key mark, drawn natively
Model.js        pure-JS parsing helpers
vpnstore        unprivileged CLI: manages the VPN list + config scan
vpnhelper       root CLI (pkexec): awg-quick up/down + route apply/remove
barstatus       unprivileged CLI: prints up/down for the bar icon
```

The plugin follows the same single-file bar-widget pattern as the first-party
`omarchy.audio` plugin: the manifest declares only the `bar-widget` kind with
`Panel.qml` as entry point, the `Panel` base item is the bar slot's content
(a `BarIconButton` renders in the bar, the `KeyboardPanel` is the popout),
and the shell routes `summon`/`toggle`/`hide` to the live bar instance.

State lives in `~/.local/share/omarchy-wgpvpn/vpns.json` — deliberately
outside the plugin directory, because a write inside
`~/.config/omarchy/plugins/` makes the shell hot-reload the plugin.

```json
{
  "vpns": [
    {
      "name": "sxott",
      "path": "/home/sxott/.config/amnezia/sxott.conf",
      "kind": "amneziawg",
      "routes": [
        { "cidr": "192.168.1.0/24", "bypass": true }
      ]
    }
  ]
}
```

- `name` is the interface name and comes from the config file name
  (`sxott.conf` -> interface `sxott`), which is what `awg-quick` requires.
- `path` is a reference in place; the plugin never copies config files.
- `kind` is detected: `amneziawg` when the `[Interface]` section carries
  AmneziaWG-specific parameters (Jc/Jmin/Jmax/S*/H*/I1), else `wireguard`.
  Both kinds are driven through `awg-quick`, which handles plain WireGuard
  configs as well.

## How up/down works

Everything privileged runs in one `pkexec` invocation
(`pkexec <plugin>/vpnhelper up|down <vpns.json> <name>`), so each toggle
costs a single polkit prompt:

- up: `awg-quick up <config>`, then each route is applied with
  `ip route replace <cidr> dev <dev>`. Regular routes ride the VPN
  interface; bypass routes ride the machine's default-route device,
  captured *before* the VPN comes up and excluding the other configured
  VPNs (so a full-tunnel VPN cannot steal the answer). Applied routes are
  recorded in `/run/omarchy-wgpvpn/<name>.routes` (tmpfs, gone on reboot).
- down: the recorded routes are removed exactly, then `awg-quick down`.

Liveness is polled unprivileged via `ip -j link show` every 5 s while the
panel is open; the bar icon refreshes every 30 s via `barstatus`.

## Config discovery

`vpnstore scan` looks in `~/.config/amnezia/`, `~/.config/wireguard/`,
`/etc/amnezia/` and `/etc/wireguard/` for `*.conf` files. On first open the
panel scans automatically when nothing is configured.

## Requirements

- `amneziawg-dkms` + `amneziawg-tools` (the `awg-quick` binary) installed.
- A polkit agent for the pkexec prompts (same mechanism Omarchy uses for
  tailscale operator authorization).

## Development notes

QML files in the plugin directory hot-reload on save, but the running shell
keeps *compiled* copies of already-instantiated components in its Qt
component cache, so edits to a QML that has already loaded once (bar widget
or an open panel) may not take effect until the shell restarts:

```sh
omarchy restart shell
```

The Python CLIs are read from disk on every invocation, so they need no
reload at all. After editing QML, check for load errors with:

```sh
journalctl --user --since "-30s" | grep -E 'wgpvpn|WARN scene'
```

## Uninstall

`omarchy plugin remove sxott.wgpvpn` (or delete the directory and rescan).
State in `~/.local/share/omarchy-wgpvpn/` can be deleted by hand; routes
applied by an up VPN disappear with the interface on down/reboot.
