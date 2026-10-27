# shmivanvpn

A macOS menu bar VPN client for 3x-ui links (VLESS over XHTTP/WS/gRPC/TCP with TLS or Reality, plus `http://`, `https://` and `socks://` upstream proxies). It uses [Xray-core](https://github.com/XTLS/Xray-core), the same engine V2Box uses.

## Build

Requirements: macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`). You don't need full Xcode.

```bash
./build.sh install
```

The build script downloads the pinned Xray-core release from GitHub and checks its SHA-256. It then compiles the app, bundles `xray`, `geoip.dat` and `geosite.dat`, copies the links from `.env` in as the first-launch server list, and checks the generated configs with `xray run -test`. Finally it ad-hoc signs the app. Set `XRAY_VERSION=vX.Y.Z` to use a different Xray release.

## Modes

- **System Proxy**: Xray listens on `127.0.0.1:10808` (SOCKS5) and `:10809` (HTTP), and the macOS system proxy points at it. No admin rights are needed. Apps that ignore system proxy settings (for example most terminal tools) are not covered.
- **TUN (full VPN)**: Xray's built-in utun inbound (`utun99`) carries all traffic. Click **Settings → General → Install** once and enter your password. This installs a root-owned helper and a sudoers rule, so connecting doesn't ask for a password again. The DNS leak option points system DNS at 1.1.1.1, sends those lookups through the tunnel, and restores your DNS settings when you disconnect.

## Split tunneling

Set this up in **Settings → Split Tunneling**:

- Choose between **VPN for everything except the list** and **VPN only for the list**.
- **Countries**: entering `ru` adds `geoip:ru` and every `*.ru` domain.
- **Domains**: `example.com` (also covers subdomains), `geosite:netflix`, `keyword:bank`, `full:a.b.c`, `regexp:…`
- **IPs**: `1.2.3.4`, `10.0.0.0/8`, `geoip:de`
- **Apps**: pick `.app` bundles. They are matched by process, which works best in TUN mode.
- **Local network always direct** and **Block ads** are toggles.

Settings are stored in `~/Library/Application Support/shmivanvpn/`. Logs are in **Settings → Logs**.

## Android

`android/` is a Jetpack Compose app with a Material 3 Expressive design. It runs the same Xray core through Android's VpnService, using [AndroidLibXrayLite](https://github.com/2dust/AndroidLibXrayLite). On wide screens, such as foldable inner displays and tablets, it switches to a navigation rail and two-pane layouts.

```bash
brew install openjdk@21 && brew install --cask android-commandlinetools
sdkmanager "platform-tools" "platforms;android-37.0" "build-tools;37.0.0"
./build-android.sh install
```

`./build-android.sh` builds signed APKs into `android/dist/`, and the `install` argument also installs the arm64 APK on the phone connected over adb. On the first build it creates a signing key at `android/keystore.jks`. Keep a backup of that file, because every update has to be signed with the same key.

To add a server, open a `vless://` link on the phone, for example by scanning the QR code in 3x-ui, or use **Paste link**. Per-app split tunneling uses Android's own app allow and deny lists. A Quick Settings tile toggles the VPN.
