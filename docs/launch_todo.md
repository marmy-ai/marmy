# Launch TODO

Ref: [prelaunch-assessment.md](prelaunch-assessment.md)

---

## Phase 1: Security
- [x] Wire auth middleware to API router (B-1)
- [x] Add auth to WebSocket endpoint — `?token=` query param (B-2)
- [x] Fix token exposure — use `tmux set-environment` instead of `export` in send-keys (C-3)
- [x] Restrict CORS — remove `allow_origin(Any)` (C-1)
- [x] Block `cwd=/` from dynamic file access paths (C-4)
- [x] Apply hidden-file filter to `read_file`/`raw_file`, not just listing (H-8)

## Phase 2: MacMarmy Installer + Distribution

User-facing install is one line:
```
curl -fsSL https://marmy.ai/install.sh | bash
```
This downloads and runs the `.pkg` installer. Users can also download the `.pkg` directly from the website.

### The `.pkg` installer handles:
- [ ] Install MacMarmy.app to `/Applications`
- [ ] Bundle pre-built `marmy-agent` (universal binary: arm64 + x86_64) inside the app
- [ ] Install tmux if missing (bundle a static binary or install via Homebrew with user prompt)
- [ ] Generate default config (`~/.config/marmy/config.toml`) with a random auth token
- [ ] Register MacMarmy for Launch at Login
- [ ] Open MacMarmy after install

### Build pipeline:
- [ ] Rename Xcode project to "MacMarmy"
- [ ] Enable Hardened Runtime (B-4)
- [ ] Create entitlements file — network.client, file access (B-5)
- [ ] Set up code signing with Developer ID cert (C-6)
- [ ] Create `scripts/build-pkg.sh` — xcodebuild > codesign > pkgbuild > productbuild > notarytool > stapler
- [ ] Create `install.sh` — detect arch, download `.pkg` from GitHub Releases or marmy.ai, run installer
- [ ] Host `.pkg` on GitHub Releases (tagged per version)

### Push notification delivery:
- [ ] Replace direct APNs with a relay (Expo Push, FCM, or custom server) — current approach requires the `.p8` signing key on every user's machine, which is a non-starter for distribution

### MacMarmy app fixes:
- [ ] Fix process race condition in AgentManager (H-7)
- [ ] Detect and display Tailscale IP alongside LAN IP (H-12)

## Phase 3: Website
- [ ] Rewrite Get Started: `curl` one-liner + "Download .pkg" button + App Store badge (B-8)
- [ ] Rewrite How It Works for MacMarmy model (B-8)
- [ ] Fix architecture diagram — port 9876, `http://`, tmux intermediary (C-9, C-10)
- [ ] Tone down file viewer claims to match MVP reality (C-11)
- [ ] Create `/privacy` page (B-3)
- [ ] Create `/terms` page (H-11)
- [ ] Write Tailscale setup guide (C-12)
- [ ] Host `install.sh` at `https://marmy.ai/install.sh`
- [ ] Create og:image (1200x630) and add meta tags (H-9)
- [ ] Fix GitHub links — `marmy-ai` or `harajlim` (H-10)
- [ ] Set up deployment — Vercel/Netlify + domain (B-7)

## Phase 4: iOS App Polish
- [ ] Add "Files" link from chat view to jump to file browser
- [ ] Fix worker card sizing — ensure consistent box sizes with odd number of workers
- [ ] Scope `NSAllowsArbitraryLoads` — use `NSAllowsLocalNetworking` + exception domains (C-5)
- [ ] Add `privacyPolicyUrl` to app.json + create `PrivacyInfo.xcprivacy` (B-3)
- [ ] Add API client timeout via AbortController (H-2)
- [ ] Add error boundaries per route (H-5)
- [ ] Replace placeholder tab icons with Ionicons (H-4)
- [ ] Add file size guard (>1MB) + FlatList in CodeViewer (H-3)
- [x] Switch terminal from 500ms REST polling to WebSocket (H-1)
- [ ] Bump version to 1.0.0 (M-29)

## Phase 5: README + Docs + Open-Source Hygiene
- [ ] Add LICENSE file (MIT)
- [ ] Remove dead `api/` directory (replaced by Rust agent)
- [ ] Remove `api/.env` from git history (`git filter-repo` or BFG)
- [ ] Add `.env` to `.gitignore`
- [ ] Add CODE_OF_CONDUCT.md
- [ ] Add GitHub Actions CI (cargo build + clippy, TypeScript type-check)
- [ ] Add issue and PR templates (`.github/`)
- [ ] Add linting/formatting config (rustfmt, eslint/prettier)
- [ ] Rewrite README for MacMarmy distribution model (C-7, C-8)
- [ ] Add Tailscale setup instructions to README
- [ ] Move dev setup to CONTRIBUTING.md
- [ ] Fix project structure — remove `parser.rs`, update descriptions (M-31)
- [ ] Document actual API endpoints (M-30)
- [x] ~~Remove WebSocket "streaming pane output" claim~~ — now implemented (M-32)

## Phase 6: Polish
- [ ] Add `exp` to APNs JWT (M-1)
- [ ] Debounce column width slider — use `onSlidingComplete` (M-6)
- [ ] MacMarmy: require 2-3 consecutive health check failures before status change (M-23)
- [ ] MacMarmy: auto-restart agent on unexpected crash (M-22)
- [ ] Add 24-bit RGB (truecolor) to ANSI parser (M-5)
- [ ] Add connection validation on machine add (M-9)
- [ ] Add connecting/loading spinners (M-10, M-17)
- [x] Add WebSocket heartbeat/keepalive (M-11)
- [ ] Wire push notification deep linking (M-19)
- [ ] Handle push token refresh (M-12)
- [ ] Unregister push tokens on disconnect (M-13)
- [ ] Add offline detection with NetInfo (M-15)
- [ ] Add accessibility labels to custom keyboard (M-18)
- [ ] Keep keyboard open when switching between MSG and KB modes

## Deferred (Post-Launch)
- [ ] Android support
- [ ] Wire up RichView.tsx / TerminalView.tsx
- [ ] Syntax highlighting in CodeViewer
- [ ] QR code pairing
- [ ] Git integration, voice input, file search
- [ ] MacMarmy auto-update (Sparkle)
- [ ] Test framework + coverage
- [ ] Light theme
