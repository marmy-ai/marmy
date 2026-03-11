# Phase 2: Step-by-Step for Marwan

Branch: `phase_2_prelaunch`

## What Claude did

- Renamed product to MacMarmy (product name, bundle ID, display name)
- Created `MacMarmy.entitlements` (network server/client, file access)
- Enabled Hardened Runtime in Debug + Release
- Created `scripts/build-pkg.sh` (build + sign + notarize pipeline, arm64 only)
- Created `scripts/install.sh` (curl one-liner that installs Homebrew, tmux, and the pkg)
- Created `scripts/pkg-scripts/postinstall` (warns about tmux, opens app)
- Fixed AgentManager race condition (H-7) — added `isStopping` flag
- Added Tailscale IP detection (H-12) — ConfigReader, PairingInfo, MenuBarView

## What Marwan does

### Step 1: Create Developer ID certificates

You need two certs. Each one requires its own unique CSR (Certificate Signing Request).

**For each cert**, repeat all three parts:

**A) Generate a fresh CSR:**
1. Open Keychain Access
2. Keychain Access > Certificate Assistant > Request a Certificate From a Certificate Authority
3. Enter your email, leave CA Email blank, select "Saved to disk"
4. Save it (e.g. `DevIDApp.certSigningRequest` for the first, `DevIDInstaller.certSigningRequest` for the second)

**B) Create the cert on Apple's site:**
1. Go to https://developer.apple.com/account/resources/certificates/list
2. Click "+"
3. First time: select **Developer ID Application**. Second time: select **Developer ID Installer**
4. When asked about Sub-CA: select **G2 Sub-CA** (requires Xcode 11.4.1+, which we have)
5. Upload the CSR you just generated

**C) Install the cert:**
1. Download the `.cer` file
2. Double-click to install in Keychain (login keychain)

### Step 2: Create an app-specific password

1. Go to https://appleid.apple.com
2. Sign-In & Security > App-Specific Passwords
3. Generate one, name it whatever (e.g. "notarytool")
4. Copy the generated password immediately — Apple only shows it once (format: `xxxx-xxxx-xxxx-xxxx`)

### Step 3: Verify certs installed

Run this to see all identities (the Installer cert won't show with `-p codesigning`):
```bash
security find-identity -v
```

You should see entries including:
```
"Developer ID Application: Marwan Harajli (P6BMHC8R6H)"
"Developer ID Installer: Marwan Harajli (P6BMHC8R6H)"
```

### Step 4: Build the .pkg

```bash
sudo rm -rf build
DEVELOPER_ID_APP="Developer ID Application: Marwan Harajli (P6BMHC8R6H)" \
DEVELOPER_ID_PKG="Developer ID Installer: Marwan Harajli (P6BMHC8R6H)" \
APPLE_ID="marwan@datalytics.pro" \
APPLE_ID_PASSWORD="<your-app-specific-password>" see notarytool in pass\
APPLE_TEAM_ID="P6BMHC8R6H" \
./scripts/build-pkg.sh
```

This will:
- Build MacMarmy.app via xcodebuild (Release)
- Build agent binary (arm64) via cargo
- Sign the app and agent with Developer ID Application cert
- Package into a `.pkg`
- Sign the `.pkg` with Developer ID Installer cert
- Submit to Apple for notarization
- Staple the notarization ticket

Output: `build/MacMarmy-1.0.0.pkg`

When Keychain prompts for password, enter your Mac login password and click "Always Allow".

### Step 5: Test the .pkg locally

```bash
sudo installer -pkg build/MacMarmy-1.0.0.pkg -target /
```

Verify:
- MacMarmy.app appears in `/Applications`
- It opens and shows in the menu bar (`open /Applications/MacMarmy.app`)
- Agent starts and health check passes
- Mobile app can connect

### Step 6: Upload to GitHub Releases

```bash
gh release create v1.0.0 build/MacMarmy-1.0.0.pkg --title "MacMarmy v1.0.0" --notes "First distributable release"
```

### Step 7: Test the install script end-to-end

After the GitHub Release exists, test the curl one-liner:
```bash
curl -fsSL https://raw.githubusercontent.com/mharajli/marmy/main/scripts/install.sh | bash
```

This will install Homebrew (if missing), install tmux (if missing), download the .pkg from GitHub Releases, and install it.

(URL becomes `https://marmy.ai/install.sh` once the website hosts it in Phase 3.)

### Step 8: Handle remaining pkg installer items

Tell Claude to do these or do them yourself:

- [ ] **Generate default config on install** — postinstall should create `~/.config/marmy/config.toml` with a random token if it doesn't exist
- [ ] **Register Launch at Login on install** — postinstall could use `osascript` or `launchctl` to register
- [ ] **Push notification relay** — replace direct APNs with Expo Push or FCM (bigger effort, likely its own branch)

### Step 9: Commit and merge

```bash
git checkout main
git merge phase_2_prelaunch
git push
```

Then check off the Phase 2 items in `docs/launch_todo.md`.
