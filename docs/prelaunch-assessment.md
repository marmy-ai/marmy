# Marmy Pre-Launch Assessment

**Date:** 2026-03-06
**Version assessed:** 0.1.0 (commit 2577ab6)
**Platform:** macOS only (v1)
**Components:** MacMarmy (macOS menu bar app + bundled Rust agent), Marmy iOS app, Astro website

---

## Distribution Model (v1)

Marmy v1 is **Mac-only**. Users never touch a terminal. The onboarding flow:

1. **Download MacMarmy** — DMG from website. Drag to Applications.
2. **MacMarmy handles everything** — installs/manages tmux, starts the Rust agent, shows connection info (IP + token) in the menu bar.
3. **Install Marmy iOS app** — from the App Store.
4. **Connect** — enter the IP address and token shown in MacMarmy. For remote access, connect via Tailscale.

Android support is deferred to a future release.

---

## 1. Verdict: NOT READY FOR LAUNCH

Marmy has strong foundations — the architecture is sound, the core workflows function, and the codebase is clean. However, there are **8 blockers** that must be resolved before any public release, plus significant security gaps that would expose users to real risk on shared networks.

**Key gaps for the new distribution model:** MacMarmy needs to bootstrap dependencies (tmux via Homebrew), the website needs a complete rewrite of its onboarding content, and the entire pipeline needs signing + notarization.

---

## 2. Blockers — Must Fix Before Any Release

### B-1. Auth middleware is defined but never wired to the API router
- **Files:** `agent/src/auth.rs:9` (definition), `agent/src/api/mod.rs:15-52` (router)
- **Impact:** The `auth_middleware` function exists but is never applied via `.layer()`. **Every API endpoint is completely unauthenticated.** Anyone on the same network can read files, send terminal input, create sessions, and trigger push notifications.
- **Fix:** Add `.layer(axum::middleware::from_fn(auth::auth_middleware))` to `api_routes` and inject the `AuthToken` extension.

### B-2. WebSocket endpoint has no authentication
- **Files:** `agent/src/api/ws.rs:15-20`
- **Impact:** The `/ws` endpoint accepts any connection with zero auth checks. A comment in `mod.rs:21` says "auth via query param or first message" but neither is implemented. Any client can connect, receive full tmux topology, and send arbitrary terminal input.
- **Fix:** Validate a `?token=` query parameter in `ws_handler` before calling `on_upgrade`, or require auth as the first message.

### B-3. No privacy policy URL or page
- **Files:** `mobile/app.json` (no `privacyPolicyUrl` field), website (no `/privacy` route)
- **Impact:** Apple requires a privacy policy URL for all App Store submissions. No `PrivacyInfo.xcprivacy` manifest exists either (required since Spring 2024). The website has no privacy policy page to link to.
- **Fix:** Create a `/privacy` page on the website. Add `privacyPolicyUrl` to `app.json`. Create a `PrivacyInfo.xcprivacy` file.

### B-4. macOS hardened runtime not enabled
- **Files:** `macos/MarmyMenuBar/MarmyMenuBar.xcodeproj/project.pbxproj:223-261`
- **Impact:** `ENABLE_HARDENED_RUNTIME` is not set. Hardened runtime is required for notarization (mandatory since macOS 10.14.5). Without it, Gatekeeper blocks MacMarmy with "cannot be opened because the developer cannot be verified."
- **Fix:** In Xcode: Signing & Capabilities > add "Hardened Runtime."

### B-5. No entitlements file for macOS app
- **Files:** `project.pbxproj:226,246` — `CODE_SIGN_ENTITLEMENTS = ""`
- **Impact:** MacMarmy spawns child processes (Rust agent), accesses the network, and reads files. Without entitlements, hardened runtime will block these operations at launch.
- **Fix:** Create `MacMarmy.entitlements` with `com.apple.security.network.client`, `com.apple.security.files.user-selected.read-only`, and potentially `com.apple.security.cs.allow-unsigned-executable-memory`.

### B-6. MacMarmy does not bootstrap dependencies (tmux)
- **Impact:** The agent requires tmux to function. Currently, users are expected to have tmux installed. In the new "no terminal" model, MacMarmy must handle this — either bundling tmux or installing it via Homebrew (prompting the user if Homebrew isn't present).
- **Fix:** On first launch, MacMarmy should check for tmux (`which tmux`). If missing, either: (a) bundle a static tmux binary in the app, or (b) prompt the user to install Homebrew + tmux with a one-click button that runs the install. Option (a) is cleaner but requires maintaining a tmux build.

### B-7. Website has no deployment configuration
- **Impact:** No `vercel.json`, `netlify.toml`, `CNAME`, or CI/CD workflow exists. The `og:url` points to `https://marmy.ai` but no hosting is configured. The site cannot go live.
- **Fix:** Set up deployment (Vercel, Netlify, or GitHub Pages). Register/configure `marmy.ai` domain.

### B-8. Website onboarding content is completely wrong for new model
- **Files:** `website/src/components/HowItWorks.astro`, `website/src/components/GetStarted.astro`
- **Impact:** Shows `pip install marmy` / `marmy start` / `marmy pair` and QR code scanning — none of this exists. The entire Get Started flow must be rewritten for the MacMarmy + iOS app model.
- **Fix:** Rewrite to reflect the actual onboarding:
  1. "Download MacMarmy for Mac" (DMG link)
  2. "MacMarmy sets up everything — tmux, the agent, networking"
  3. "Install Marmy from the App Store" (badge link)
  4. "Enter the IP and token from MacMarmy's menu bar"
  5. "For remote access, set up Tailscale" (link to guide)

---

## 3. Critical — Should Fix Before Launch

### C-1. CORS allows any origin
- **File:** `agent/src/api/mod.rs:16-19`
- `CorsLayer::new().allow_origin(Any).allow_methods(Any).allow_headers(Any)` — once auth is wired (B-1), any website visited on the same network can still make cross-origin requests if it guesses the token.
- **Fix:** Restrict to specific origins or remove CORS entirely (mobile app uses fetch, not browser).

### C-2. `/api/notifications/send` is an open push relay
- **File:** `agent/src/api/notifications.rs:58-90`
- Combined with B-1, anyone on the network can trigger arbitrary push notifications to the user's phone.
- **Fix:** Wiring auth (B-1) fixes this. The Claude Stop hook curl command should include `-H "Authorization: Bearer $MARMY_TOKEN"`.

### C-3. Auth token visible in process listing and shell history
- **Files:** `agent/src/api/sessions.rs:87-89`, `agent/src/api/cc.rs:339-341`
- `tmux send-keys` sends `export MARMY_TOKEN='<token>' && claude ...` as literal text. The token appears in `ps aux`, shell history, and tmux scrollback captured via `capture_pane`.
- **Fix:** Use `tmux set-environment -t <session> MARMY_TOKEN <token>` to inject the variable, then launch `claude` separately.

### C-4. Pane with `cwd=/` exposes entire filesystem
- **File:** `agent/src/api/files.rs:262-289`
- `is_path_allowed_dynamic` checks if the requested path starts with any pane's `current_path`. If a pane's cwd is `/`, then `canonical.starts_with("/")` is always true, granting read access to every file on the system.
- **Fix:** Filter out pane paths that are `/` (or depth < 2) from dynamic allowed-paths. Or require explicit opt-in.

### C-5. `NSAllowsArbitraryLoads: true` — App Store review risk
- **Files:** `mobile/app.json:15-17`, `mobile/ios/Marmy/Info.plist:41-44`
- Apple flags this during review. Since the app connects to user-specified LAN/Tailscale addresses, a blanket exception may be necessary but needs justification.
- **Fix:** Use `NSAllowsLocalNetworking: true` + `NSExceptionDomains` instead of blanket arbitrary loads. Add App Store review notes explaining the use case.

### C-6. macOS: no code signing or notarization pipeline
- **File:** `macos/MarmyMenuBar/Scripts/build-agent.sh` — uses `CODE_SIGNING_ALLOWED=NO`
- MacMarmy cannot be distributed without signing + notarization. This is the cornerstone of the new distribution model.
- **Fix:** Create a `scripts/package.sh`: xcodebuild > codesign > create-dmg > notarytool submit > stapler staple.

### C-7. README fundamentally inaccurate about core architecture
- **File:** `README.md:14,22,251-258`
- Claims tmux control mode (`-CC`) with `%output`/`%window-add` parsing. Actual implementation uses subprocess-per-command (`Command::new("tmux")`). Also claims WebSocket streams pane output; it only pushes topology updates.
- **Fix:** Rewrite "How It Works" section to reflect actual architecture, the Mac-only model, and MacMarmy as the entry point. Remove `-CC` references, `parser.rs` from project structure (doesn't exist), and "streaming pane output" from WebSocket description.

### C-8. README Quick Start recommends Expo Go — won't work
- **File:** `README.md:33,107-108`
- The app uses `expo-notifications`, `expo-secure-store`, `react-native-webview` — none available in Expo Go. The README should reflect the new model: "Download MacMarmy + install iOS app."
- **Fix:** Rewrite Quick Start for the MacMarmy distribution model. Dev setup instructions should be in a separate CONTRIBUTING.md.

### C-9. Website architecture diagram has wrong port and misleading protocol
- **File:** `website/src/components/HowItWorks.astro:44,48-49`
- Shows `ws://` on port `:8765`. Actual default port is `9876` (`agent/src/config.rs:101`). The mobile app primarily uses REST polling, not WebSocket streaming.
- **Fix:** Change `:8765` to `:9876`. Simplify to show `http://` since that's what users see.

### C-10. Website architecture diagram misrepresents Claude Code integration
- **File:** `website/src/components/HowItWorks.astro:45-46`
- Shows agent connecting to Claude Code via `stdin/stdout` as a `(subprocess)`. Actually, the agent interacts with Claude Code through tmux panes.
- **Fix:** Show `tmux` as the intermediary: `MacMarmy agent --> tmux --> Claude Code (in panes)`.

### C-11. Website file viewer claims overstate MVP implementation
- **File:** `website/src/components/FileViewer.astro:13-27`
- Claims "Syntax-highlighted code in any language" and "Rendered markdown with full formatting." CodeViewer.tsx explicitly says it's "MVP: renders plain monospace text with line numbers."
- **Fix:** Soften claims to match reality, or implement syntax highlighting before launch.

### C-12. Tailscale setup guide needed
- **Impact:** Remote access (outside LAN) is a core use case. Users need clear instructions for setting up Tailscale on both their Mac and iPhone. No documentation exists for this.
- **Fix:** Create a comprehensive Tailscale setup guide covering: (1) Install Tailscale on Mac + iPhone, (2) Create/join a tailnet, (3) Use the Tailscale IP (100.x.x.x) in Marmy instead of LAN IP, (4) Verify connectivity. Add this to both the website and README. Consider having MacMarmy detect Tailscale and show the Tailscale IP alongside the LAN IP.

---

## 4. High — Strongly Recommended Before Launch

### H-1. 500ms REST polling for terminal content
- **File:** `mobile/app/(tabs)/terminal.tsx:224-244`
- `setInterval(poll, 500)` fetches full pane scrollback via REST every 500ms. The WebSocket is connected but unused for content. Significant battery and bandwidth impact.
- **Fix:** Use WebSocket `subscribePane()` for content streaming. Fall back to REST only when WebSocket disconnects.

### H-2. API client has no timeout
- **File:** `mobile/src/services/api.ts:24-42`
- Global `fetch()` with no `AbortController`. A hung server leaves requests pending indefinitely.
- **Fix:** Add `AbortController` with 10s timeout. Add retry with backoff for idempotent GETs.

### H-3. CodeViewer renders all lines without virtualization
- **Files:** `mobile/src/components/CodeViewer.tsx:28-67`
- Every line rendered as `View` + two `Text` in a non-virtualized `ScrollView`. No file size check before loading (`files.tsx:101-131`). A 50MB log file will crash the app.
- **Fix:** Add a size guard (refuse files >1MB), replace `ScrollView` with `FlatList` for windowing.

### H-4. Tab bar icons are placeholder text
- **File:** `mobile/app/(tabs)/_layout.tsx:4-9,30-58`
- `TabIcon` renders single characters ("M", "S", "T", "F"). Not production-ready.
- **Fix:** Use `@expo/vector-icons` Ionicons: `server-outline`, `layers-outline`, `terminal-outline`, `folder-outline`.

### H-5. No error boundaries
- No React error boundary components anywhere in the mobile app. An unhandled JS error crashes the entire app with a white screen.
- **Fix:** Add `ErrorBoundary` exports per route file (Expo Router supports this natively).

### H-6. No test framework configured (mobile)
- **File:** `mobile/package.json`
- No jest, vitest, or any testing library. Zero test coverage.
- **Fix:** Add Jest + React Native Testing Library. At minimum, add snapshot tests for critical screens.

### H-7. macOS: Process race condition
- **File:** `macos/MarmyMenuBar/MarmyMenuBar/AgentManager.swift:83-107`
- `terminationHandler` dispatches to MainActor to set `self.process = nil`. The success path also dispatches to set `self.process = proc`. If the process exits instantly, these two MainActor tasks race — could leave a dangling reference to a dead process.
- **Fix:** Set `self.process = proc` before calling `proc.run()`, or check `proc.isRunning` in the success handler.

### H-8. Hidden files readable despite listing filter
- **File:** `agent/src/api/files.rs:135` (filters `.` files in listing) vs lines 166-226 (no filter in `read_file`/`raw_file`)
- `.env`, `.git/config`, `.ssh/authorized_keys` etc. are hidden in directory listings but directly readable by path.
- **Fix:** Add hidden-file filtering to `read_file`/`raw_file`, or remove the filter from `list_dir` for consistency.

### H-9. Website missing og:image for social sharing
- **File:** `website/src/layouts/Layout.astro:18-25`
- Has `og:title`, `og:description`, `twitter:card` (set to `summary_large_image`) but no `og:image` or `twitter:image`. Social shares will show blank/generic previews.
- **Fix:** Create an OG image (1200x630px) and add `og:image` + `twitter:image` meta tags.

### H-10. Website GitHub links point to nonexistent organization
- **Files:** `website/src/components/Nav.astro:8`, `Hero.astro:22`, `Footer.astro:8,16`
- All links point to `https://github.com/marmy-ai/marmy`. Actual repo is `github.com/harajlim/marmy`. These will 404.
- **Fix:** Update to correct repo URL, or create the `marmy-ai` org and transfer the repo.

### H-11. Website missing terms of service and contact info
- No terms of service, support email, or contact information anywhere on the site.
- **Fix:** Add a `/terms` page and a support/contact email in the footer.

### H-12. MacMarmy should show Tailscale IP alongside LAN IP
- **File:** `macos/MarmyMenuBar/MarmyMenuBar/ConfigReader.swift:40-69`
- Currently shows only the LAN IP. For the recommended Tailscale flow, MacMarmy should detect the `utun` Tailscale interface and display the 100.x.x.x address too, making it trivial for users to connect remotely.
- **Fix:** In `detectLocalIP()`, also scan for Tailscale interfaces (IPs in 100.64.0.0/10 range). Show both LAN and Tailscale IPs in the menu bar dropdown.

---

## 5. Medium — Nice to Have for Launch

| ID | Area | Finding | File |
|----|------|---------|------|
| M-1 | Agent | APNs JWT missing `exp` field | `notifications.rs:118` |
| M-2 | Agent | `send_bytes` silently swallows errors | `tmux/control.rs:161-162` |
| M-3 | Agent | Stale topology on polling failure (no unhealthy state) | `main.rs:89-96` |
| M-4 | Agent | Blocking `std::fs` I/O in async context (cc.rs) | `api/cc.rs:147-268,306,315` |
| M-5 | Mobile | ANSI parser missing 24-bit RGB (truecolor) | `terminal.tsx:89-113` |
| M-6 | Mobile | Column width slider fires resize on every drag step | `terminal.tsx:419` |
| M-7 | Mobile | TerminalView.tsx (xterm.js) exists but unused (dead code) | `src/components/TerminalView.tsx` |
| M-8 | Mobile | Session deletion only via long-press | `sessions.tsx:316` |
| M-9 | Mobile | No connection validation on machine add | `index.tsx:33-43` |
| M-10 | Mobile | No connecting spinner on machine connect | `index.tsx:62-69` |
| M-11 | Mobile | WebSocket: no heartbeat/keepalive | `services/websocket.ts` |
| M-12 | Mobile | Push token refresh not handled | `services/notifications.ts:16-55` |
| M-13 | Mobile | Push tokens not unregistered on disconnect | `stores/connectionStore.ts:124-136` |
| M-14 | Mobile | ConnectionStore has no loading/error state | `stores/connectionStore.ts:24-41` |
| M-15 | Mobile | No offline detection or feedback | (no NetInfo usage) |
| M-16 | Mobile | No retry mechanisms on failed operations | Multiple empty `catch {}` blocks |
| M-17 | Mobile | Missing loading spinners (machines, terminal init) | `index.tsx`, `terminal.tsx` |
| M-18 | Mobile | No accessibility labels on custom keyboard | `terminal.tsx:450-481` |
| M-19 | Mobile | Push notification deep linking not wired | `notifications.ts:69-77` |
| M-20 | Mobile | RichView.tsx exists but not wired up (dead code) | `src/components/RichView.tsx` |
| M-21 | Mobile | No QR code pairing for onboarding | (not implemented) |
| M-22 | macOS | No auto-restart on agent crash | `AgentManager.swift:83-94` |
| M-23 | macOS | Health check flicker (single failure downgrades status) | `AgentManager.swift:155-178` |
| M-24 | macOS | TOML regex parser fragile (comments, sections) | `ConfigReader.swift:26-35` |
| M-25 | macOS | No DMG creation script | (no packaging tooling) |
| M-26 | macOS | No auto-update mechanism | (no Sparkle) |
| M-27 | macOS | Info.plist missing `NSAllowsLocalNetworking` | `Info.plist` |
| M-28 | iOS | Splash screen logo not in view hierarchy | `SplashScreen.storyboard:19` |
| M-29 | iOS | Version 0.1.0 (bump for launch) | `app.json:5` |
| M-30 | README | Missing 4 API routes from documentation | `README.md` |
| M-31 | README | Lists nonexistent `parser.rs` in project structure | `README.md:738` |
| M-32 | README | Claims WebSocket streams pane output (it doesn't) | `README.md:287` |
| M-33 | Website | No app download links or store badges | (not present) |
| M-34 | Website | No canonical URL tag | `layouts/Layout.astro` |
| M-35 | Website | No robots.txt or sitemap.xml | (not present) |

---

## 6. Low — Future Improvements

| ID | Area | Finding |
|----|------|---------|
| L-1 | Agent | Token comparison not timing-safe (`==` vs constant-time) |
| L-2 | Agent | `|||` tmux delimiter could conflict with session names |
| L-3 | Agent | `_marmy_ctrl` session not cleaned up on agent exit |
| L-4 | Agent | No config validation (bad bind addresses fail at runtime) |
| L-5 | Agent | Tilde expansion inconsistency between `files.rs` and `notifications.rs` |
| L-6 | Agent | `canonicalize()` rejects non-existent paths (fail-closed, not a vulnerability) |
| L-7 | Agent | Claude detection heuristic overly broad (any digit-starting command) |
| L-8 | Agent | JSONL path encoding guessing limited to 2 candidates |
| L-9 | Agent | `rand` 0.8 slightly outdated (0.9 available) |
| L-10 | Mobile | No certificate pinning (only relevant if HTTPS added) |
| L-11 | Mobile | Markdown XSS partially mitigated (JS disabled in WebView) |
| L-12 | Mobile | WebSocket handler cleanup not stored (mitigated by disconnect) |
| L-13 | Mobile | Notify toggle state not persisted across restarts |
| L-14 | Mobile | `@types/marked` in `dependencies` instead of `devDependencies` |
| L-15 | Mobile | Dark-only theme (valid design choice for terminal app) |
| L-16 | Mobile | No git integration, voice input, or file search |
| L-17 | macOS | Local IP fallback to `127.0.0.1` on error (no warning) |
| L-18 | macOS | Launch at Login toggle can drift out of sync |
| L-19 | macOS | No copy feedback on "Copy Address/Token" |
| L-20 | iOS | No icon/splash in `app.json` (native files exist but fragile) |
| L-21 | Mobile | Edit flow silently preserves old values on empty fields |
| L-22 | Mobile | MAX_LINES truncation silent (no user notification) |
| L-23 | Website | No analytics setup |
| L-24 | Website | Favicon color (purple) doesn't match site accent (green) |
| L-25 | Website | Screenshot PNGs in `website/screenshots/` unused |
| L-26 | Website | Built `dist/` may go stale without CI/CD |

---

## 7. What's Working Well

- **Architecture** — Clean separation of concerns: Rust agent handles tmux, mobile app is purely a client. No tight coupling.
- **Tmux integration** — Subprocess-per-command is simple and robust. The 2s polling interval is reasonable. Session creation, deletion, and input all work.
- **Security storage** — Mobile app correctly uses `expo-secure-store` (iOS Keychain) for tokens.
- **Push notifications** — APNs integration is mostly functional (JWT, HTTP/2, token persistence). Just needs the `exp` claim.
- **Build optimization** — Rust release profile has `opt-level = "z"`, `lto = true`, `strip = true`. Good for a lightweight daemon.
- **Dependencies** — All major dependencies are current (Expo 54, React Native 0.81.5, Tokio 1, Axum 0.7, Reqwest 0.12).
- **MacMarmy menu bar** — Clean SwiftUI implementation. Agent lifecycle management, config reading, and pairing info display all functional. Already bundles the Rust agent via `build-agent.sh`.
- **File browsing** — Directory tree navigation, file reading, and raw file serving all work. Path traversal protection via `canonicalize()` is correct (symlinks resolved before check).
- **Session management** — Full lifecycle: create sessions, attach panes, pick directories, manage session-manager sessions.
- **Build script** — `set -euo pipefail` in the macOS build script properly fails fast on cargo errors.
- **Website** — Excellent performance (~48KB total), responsive layout, semantic HTML, no JS frameworks. Clean Astro + Tailwind setup.

---

## 8. Recommended Launch Sequence

### Phase 1: Security (Day 1)
1. Wire auth middleware to API router (B-1)
2. Add WebSocket authentication (B-2)
3. Fix token exposure in shell commands (C-3)
4. Restrict CORS (C-1)
5. Filter `cwd=/` from dynamic file access (C-4)
6. Filter hidden files in read endpoints (H-8)

### Phase 2: MacMarmy + Distribution (Days 2-3)
7. Add tmux dependency bootstrapping to MacMarmy (B-6)
8. Enable hardened runtime + create entitlements (B-4, B-5)
9. Set up code signing + notarization pipeline (C-6)
10. Create DMG packaging script (M-25)
11. Fix process race condition (H-7)
12. Add Tailscale IP detection to MacMarmy menu (H-12)
13. Rename app to "MacMarmy" in Xcode project

### Phase 3: Website Rewrite (Days 2-3, parallel with Phase 2)
14. Rewrite Get Started / How It Works for MacMarmy model (B-8)
15. Fix architecture diagram: port, protocol, tmux intermediary (C-9, C-10)
16. Soften file viewer feature claims to match reality (C-11)
17. Create privacy policy page (B-3)
18. Create terms of service page (H-11)
19. Add "Download MacMarmy" button + App Store badge (M-33)
20. Create and add og:image (H-9)
21. Fix GitHub links (H-10)
22. Create Tailscale setup guide page (C-12)
23. Set up deployment (B-7)

### Phase 4: iOS App Polish (Days 4-5)
24. Fix `NSAllowsArbitraryLoads` scoping (C-5)
25. Add API client timeout + retry (H-2)
26. Add error boundaries (H-5)
27. Replace placeholder tab icons (H-4)
28. Add file size guard + CodeViewer virtualization (H-3)
29. Switch terminal to WebSocket content streaming (H-1)
30. Bump version to 1.0.0 (M-29)

### Phase 5: README + Docs (Day 5)
31. Rewrite README for MacMarmy distribution model (C-7, C-8)
32. Add comprehensive Tailscale instructions to README
33. Move dev setup to CONTRIBUTING.md
34. Update API endpoint list and project structure (M-30, M-31, M-32)

### Phase 6: Remaining Polish (Day 6+)
35. APNs JWT `exp` field (M-1)
36. Column slider debounce (M-6)
37. MacMarmy: health check flicker, auto-restart (M-22, M-23)
38. Mobile: offline detection, accessibility, push deep linking
39. Mobile: connection validation, loading spinners

### Deferred (Post-Launch)
- Android support
- Wire up RichView.tsx / TerminalView.tsx
- Implement syntax highlighting in CodeViewer
- QR code pairing
- Git integration, voice input, file search
- MacMarmy auto-update (Sparkle)
- Test framework + coverage
- Light theme support

---

## Appendix: Finding Counts

| Severity | Count |
|----------|-------|
| Blocker | 8 |
| Critical | 12 |
| High | 12 |
| Medium | 35 |
| Low | 26 |
| **Total** | **93** |
