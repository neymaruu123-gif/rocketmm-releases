# VPN panel + app — downloads

**One VPS, everything:** admin panel, VLESS / VMess (WebSocket, 443 TLS + 80), SSH (WebSocket 443 + 80, and port 22),
plus your own branded Android app built on GitHub.

```bash
curl -fsSL https://raw.githubusercontent.com/neymaruu123-gif/rocketmm-releases/main/vpn-panel.sh -o vpn-panel.sh
sudo BUNDLE_KEY=<your bundle key> bash vpn-panel.sh
```

It asks for the VPN name and the panel domain, then does the rest. Run it again to update.

Other files: `vpn-builder.sh` (Mac app builder), `install-backend.sh` (older panel-only installer),
`RocketMM-*.apk` + `latest.json` (RocketMM app updates).
