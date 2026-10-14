# sxott.wgpvpn — WireGuard / AmneziaWG control panel

An Omarchy shell plugin: discovers WireGuard and AmneziaWG client configs,
toggles each VPN up/down from the bar, and manages per-VPN extra routes
(including LAN bypass routes).

## Install

```sh
omarchy plugin add https://github.com/<you>/<repo>.git --enable
```

## Requirements

- **AmneziaWG VPNs** — `amneziawg-tools` (the `awg-quick` binary).
- **Plain WireGuard VPNs** — `wireguard-tools` (`wg-quick`);
  `amneziawg-tools` works for these too.

Which tool is available is detected automatically when the panel opens and
re-checked on every scan, so installing a tool later is picked up without a
restart. A VPN whose required tool is missing shows a hint on its row and
its toggle is disabled.

- A polkit agent (standard on desktops). No custom polkit rule is needed —
  each toggle gets one ordinary password prompt.

## Usage

- **Click the key icon** in the bar to open the panel. The icon is tinted
  while any configured VPN is up.
- **Toggle a VPN** with the switch on its row. The row shows the tunnel
  address while up.
- **Manage routes** — click the ▸ (or the row). Add a CIDR like
  `192.168.1.0/24`; with *bypass LAN* on, that CIDR is routed around the
  tunnel via your regular network interface (off = through the tunnel).
  Stored routes are listed under the VPN and can be deleted individually.
- **Scan for configs** — the ↻ button in the panel header (or the button in
  the empty panel) rescans `~/.config/amnezia/`, `~/.config/wireguard/`,
  `/etc/amnezia/`, `/etc/wireguard/`. Found configs can be added to the list.
- **Refresh status immediately** — middle-click the bar icon (otherwise it
  refreshes every 30 s).
- **Escape** or a click outside closes the panel.

## Uninstall

```sh
omarchy plugin remove sxott.wgpvpn
```

State lives in `~/.local/share/omarchy-wgpvpn/` and can be deleted by hand.
Routes applied by an up VPN disappear with the interface on down/reboot.

## How it works

- Config files are used **in place, never copied or modified**. Your VPN's
  interface name is the config file name (`sxott.conf` → `sxott`).
- AmneziaWG configs are recognized by their AmneziaWG-specific
  `[Interface]` parameters; everything else is treated as plain WireGuard.
- The only privileged step is one `pkexec` helper invocation per toggle:
  it runs the appropriate `*-quick` up/down for that VPN and applies or
  removes exactly the routes you added. No daemons, no services, nothing
  installed.
- Routes the plugin applied are recorded in `/run/omarchy-wgpvpn/` (tmpfs)
  so a down removes precisely what an up added.

## License

MIT — see `LICENSE`.
