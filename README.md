# NeverSleep

**Close your MacBook lid and keep your AI agents and apps running in the background. No more leaving the lid half-closed.**

The goal of this project is simple. You start a long job on your Mac: an AI coding agent, a model download, a build, a scraper, a render. Then you need to leave, and the job stops when you close the lid. The usual workarounds are keeping the lid propped half-open, or plugging in an external display. NeverSleep lets you close the lid properly and keeps only the apps you chose running. You can check on the Mac and control it from your phone's browser.

<p align="center"><i>macOS menu bar app · privileged helper · Cloudflare relay · mobile web dashboard</i></p>

---

## What it does

- **Keeps chosen apps running with the lid closed.** Pick apps from an allow-list, such as your terminal, Claude, Cursor, Ollama, a browser or a download manager. Everything else is **paused** (`SIGSTOP`) while the lid is closed, so it doesn't drain the battery, and **resumed** (`SIGCONT`) when you open it.
- **Safety cutoffs.** Below a battery level (default 20%, only when unplugged), or when macOS reports serious or critical thermal pressure, NeverSleep resumes everything, re-enables sleep and puts the Mac to sleep.
- **Remote dashboard in any browser.** Nothing to install on your phone. You see:
  - battery, charging and time remaining
  - lid state and thermal state
  - running apps, with **Pause / Resume / Quit / Force quit**
  - a search to open any installed app
  - lid mode on/off
  - the allow-list editor
  - online status and last seen
- **No passwords.** A browser signs in by typing a one-time code shown in the Mac's menu bar.
- **Crash-safe.** If NeverSleep quits, crashes or is killed, sleep is re-enabled and every paused app is resumed.

## How it works

macOS can't keep one app awake while the rest of the Mac sleeps, so NeverSleep keeps the **whole Mac** awake with `pmset disablesleep 1`. That's the same mechanism Amphetamine's closed-lid mode uses; `caffeinate` and power assertions don't stop lid-close sleep. It then freezes every app that's not on your list. When the lid opens, the frozen apps resume and normal sleep returns.

```
┌──────────── Your Mac ────────────┐            ┌──── Cloudflare (free plan) ────┐        ┌── Any browser ──┐
│ NeverSleep.app (menu bar)        │  outbound  │ Worker + Durable Objects       │ HTTPS  │ Dashboard       │
│  • watches the lid (IOKit)       │ WebSocket  │  • one Durable Object per Mac  │◀──────▶│ (phone/laptop)  │
│  • pauses/resumes apps           │──────────▶ │  • pairing + sign-in codes     │        └─────────────────┘
│  • battery + thermal cutoffs     │   (TLS)    │  • fixed, validated commands   │
│ NeverSleepHelper (root daemon)   │            │  • static dashboard            │
│  • only: pmset disablesleep 0|1  │            └────────────────────────────────┘
└──────────────────────────────────┘
```

The Mac only makes outbound connections, so it works behind any router or NAT, with no port forwarding.

## Requirements

- A MacBook running **macOS 14 Sonoma or later** (Apple Silicon or Intel)
- **Xcode Command Line Tools** (`xcode-select --install`). Full Xcode is not needed.
- **Node.js 18+** and a **free Cloudflare account**, only if you want the remote dashboard

## Quick start

### 1. Deploy your relay (for the remote dashboard)

Everyone runs their own relay, so your Mac never talks to someone else's server.

```bash
git clone https://github.com/devasahithiyan/NeverSleep.git
cd NeverSleep/relay
npm install
```

```bash
npx wrangler login
```

```bash
openssl rand -hex 32 | npx wrangler secret put SESSION_SECRET
```

```bash
npx wrangler deploy
```

Wrangler prints your URL, for example `https://neversleep-relay.<your-subdomain>.workers.dev`.

### 2. Build and install the Mac app

```bash
cd ../mac
scripts/build-app.sh --install
```

This builds and signs `NeverSleep.app` and installs it in `/Applications`. It also installs the helper; macOS asks for your administrator password once.

### 3. Choose your apps

Click the NeverSleep icon in the menu bar, then **Settings… → Apps**:
- **Keep running:** tick the apps that should run with the lid closed.
- **Quit instead:** use this for apps you'd rather quit than pause.

Then switch on **Keep apps running with lid closed**.

### 4. Pair your phone

1. On the Mac, open **Settings → Remote**, paste your relay URL and click **Pair this Mac**.
2. Open the relay URL on your phone and type the 8-character code shown on the Mac.

To sign in another browser later, use **Show code to sign in a browser** in the menu. Sign your phone in before you leave home: sign-in always needs a code from the Mac.

### 5. Try it without closing the lid

Menu bar → **Simulate lid closed**. This runs the real actions, then you can check:

```bash
pmset -g | grep SleepDisabled    # → 1 while active
```

Turn the toggle off and everything resumes. Then try a real lid close on a desk before trusting it in a bag.

## Menu bar states

| Icon | State |
|---|---|
| 🌙 `moon.zzz` | Off |
| 💻 `laptopcomputer` | Armed: will engage when the lid closes |
| ⚡ `bolt.fill` | Lid closed, active: allowed apps running, others paused |
| ⚠️ | Safety cutoff (battery or heat) |

Some apps are never paused: NeverSleep itself, Finder, Dock, SystemUIServer, Control Center, loginwindow, Spotlight, System Settings and Activity Monitor (so you can always unfreeze things by hand).

## Security

NeverSleep can control your Mac from the internet, so the attack surface is deliberately small.

- **Fixed command set.** The dashboard can only send: refresh, list installed apps, quit / force quit / pause / resume an app (by PID), open an installed app (by bundle ID), switch lid mode, and edit the allow-list. **There is no shell, script or file command.** Every command is validated with exact argument keys on the relay **and again on the Mac**.
- **The root helper does one thing.** Its XPC interface has one method, `setDisableSleep(Bool)`. It only accepts calls from the NeverSleep build it was installed for: the app's code-signing requirement is pinned in a root-owned file at install time. The app in turn only talks to the root-owned helper.
- **Device token.** When pairing, the Mac generates a random 256-bit token and sends only its SHA-256 to the relay. The token lives in the macOS Keychain.
- **Sign-in codes.** 8 characters (about 8.5×10¹¹ combinations), valid for 10 minutes, single use, rate-limited to 10 tries per 5 minutes per IP. A browser can only reach the Macs whose codes it entered, so pairing a fake Mac gives no access to anyone else's. **Sign out all browsers** on the Mac revokes every session immediately.
- **Transport.** HTTPS/WSS only, with HSTS. Cookies are HMAC-signed, `HttpOnly`, `Secure` and `SameSite=Strict`, and cross-origin POSTs are rejected. The dashboard is served with a strict CSP and loads no third-party scripts.
- **Rate limits.** Commands: 60/min per Mac. Mac messages: 240/min. Pairing: 10 per 10 min per IP. Messages are size-capped.

Rotate the cookie key to sign every browser out of every Mac:

```bash
openssl rand -hex 32 | npx wrangler secret put SESSION_SECRET
```

## Safety behaviour

| Situation | What NeverSleep does |
|---|---|
| Lid opens | Resumes the apps it paused, then `disablesleep 0` |
| Battery below cutoff (unplugged), or thermal state *serious/critical* | Resumes everything, `disablesleep 0`, then `pmset sleepnow`. Stays off until the lid is opened again |
| Lid closes while already unsafe | Doesn't engage |
| Helper not installed | Pauses nothing and shows an error |
| Quit (menu, ⌘Q, `SIGTERM`/`SIGINT`/`SIGHUP`) | Resumes all paused apps, `disablesleep 0` |
| Crash or `kill -9` | A watchdog process resumes paused apps, the helper re-enables sleep, and the next launch double-checks both |
| A paused app's PID was reused | Not signalled (the process start time is checked) |

## Known limits

- **Heat.** A closed, awake MacBook in a bag can get hot. The thermal cutoff is a backstop, not a guarantee. A hard surface or a stand is best.
- **Paused apps may lose network connections** (chat apps, VPNs, downloads). Use **Quit instead** for apps that don't reconnect well.
- **Only regular (Dock) apps are paused.** Background daemons and menu bar agents keep running.
- **The dashboard needs the Mac online.** If the network drops, the dashboard shows the Mac as offline with a last-seen time. The app reconnects automatically.
- **Whole-system setting.** While lid mode is active, the Mac doesn't idle-sleep either.
- **Ad-hoc signing.** Builds are ad-hoc signed, which is fine for your own Mac. After each rebuild, the helper is reinstalled (one password prompt) and macOS may ask once to allow Keychain access. Sign with a Developer ID (`SIGN_IDENTITY=...`) to distribute binaries.
- **Testing so far.** Lid logic is covered by unit tests and the *Simulate lid closed* mode. Please report results from real lid closes on different Mac models.

## Development

```bash
cd mac
swift build
swift run NeverSleepSelfTest     # lid-mode state machine + command validation tests
```

`NeverSleepSelfTest` is a plain executable rather than an XCTest target, because the Command Line Tools ship without the XCTest or Swift Testing macro plugins. For the same reason the UI avoids SwiftUI's `@State`.

Relay:

```bash
cd relay
cp .dev.vars.example .dev.vars   # then set SESSION_SECRET
npx wrangler dev                 # http://localhost:8787 (the Mac app accepts localhost)
npm run typecheck
node scripts/smoke-test.mjs      # end-to-end: pairing, fake Macs, commands, auth, revocation
```

The smoke test claims several codes, so run it at most once every 5 minutes or it trips the rate limit.

If your project folder is synced by iCloud Drive (for example on the Desktop), that's fine: `build-app.sh` assembles and signs the app in `~/Library/Caches/NeverSleep`, because iCloud adds file attributes that break code signatures.

### Project layout

```
mac/
  Sources/NeverSleepCore/      lid-mode state machine, models, RemoteCommand validation (no AppKit)
  Sources/NeverSleepShared/    XPC protocol, identifiers, code-signing helpers
  Sources/NeverSleep/          SwiftUI menu bar app, IOKit lid/battery monitors, relay client, watchdog
  Sources/NeverSleepHelper/    the root launch daemon
  Sources/NeverSleepSelfTest/  tests
  Support/                     Info.plist, install-helper.sh
  scripts/build-app.sh         build, sign, install
relay/
  src/                         Worker, Hub and Device Durable Objects, command validation, sessions
  public/                      dashboard (HTML/CSS/JS, no build step)
  scripts/smoke-test.mjs       end-to-end test
```

### Uninstall

1. NeverSleep → Settings → Helper → **Uninstall** (removes the root helper).
2. Quit NeverSleep and move `/Applications/NeverSleep.app` to the Trash.
3. Optionally delete your relay:

   ```bash
   npx wrangler delete
   ```

## Contributing

Issues and pull requests are welcome, especially:
- results from real lid-close tests on different Macs
- Developer ID signing and notarized releases
- other relay backends

Please keep the remote command set small and validated on both sides.

## License

[MIT](LICENSE). Free to use, modify and distribute.

**Disclaimer:** running a closed laptop for long periods can make it hot. Use NeverSleep at your own risk, and keep the safety cutoffs on.
