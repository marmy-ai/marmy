# Marmy Push Relay

Minimal serverless function that forwards push notifications to APNs on behalf of App Store builds. The agent POSTs `{ device_token, title, body, session_name }` to the relay, which authenticates with Apple and delivers the push.

## Request format

```json
POST /
Content-Type: application/json
Authorization: Bearer <RELAY_SECRET>   (optional)

{
  "device_token": "abc123...",
  "title": "worker-1",
  "body": "Task complete",
  "session_name": "worker-1"
}
```

## Environment variables

| Variable | Required | Description |
|----------|----------|-------------|
| `APNS_KEY_BASE64` | Yes | Your `.p8` key file, base64-encoded: `base64 < AuthKey_XXXXXXXXXX.p8` |
| `APNS_KEY_ID` | Yes | 10-character Key ID from Apple Developer portal |
| `APNS_TEAM_ID` | Yes | Your Apple Developer Team ID |
| `APNS_TOPIC` | No | Bundle ID (default: `com.marmy.app`) |
| `APNS_SANDBOX` | No | `"true"` for dev builds, omit for production |
| `RELAY_SECRET` | No | Shared secret for authenticating agent requests |

## Deploy to AWS Lambda

1. **Create the function:**

```bash
cd relay
zip relay.zip index.mjs
aws lambda create-function \
  --function-name marmy-push-relay \
  --runtime nodejs20.x \
  --handler index.handler \
  --zip-file fileb://relay.zip \
  --role arn:aws:iam::YOUR_ACCOUNT:role/lambda-basic-role
```

2. **Set environment variables:**

```bash
# Encode your p8 key
APNS_KEY=$(base64 < ~/.marmy/apns_key.p8)

aws lambda update-function-configuration \
  --function-name marmy-push-relay \
  --environment "Variables={APNS_KEY_BASE64=$APNS_KEY,APNS_KEY_ID=XXXXXXXXXX,APNS_TEAM_ID=XXXXXXXXXX,RELAY_SECRET=your-secret}"
```

3. **Create a function URL (no API Gateway needed):**

```bash
aws lambda create-function-url-config \
  --function-name marmy-push-relay \
  --auth-type NONE

# Returns: https://xxxxxxxxxx.lambda-url.us-east-1.on.aws/
```

4. **Configure the agent:**

```toml
# ~/.config/marmy/config.toml
[notifications]
relay_url = "https://xxxxxxxxxx.lambda-url.us-east-1.on.aws/"
```

## Deploy to Cloudflare Workers

1. **Install wrangler:**

```bash
npm install -g wrangler
wrangler login
```

2. **Set secrets:**

```bash
cd relay
base64 < ~/.marmy/apns_key.p8 | wrangler secret put APNS_KEY_BASE64
wrangler secret put APNS_KEY_ID
wrangler secret put APNS_TEAM_ID
wrangler secret put RELAY_SECRET
```

3. **Deploy:**

```bash
wrangler deploy
# Returns: https://marmy-push-relay.your-subdomain.workers.dev
```

4. **Configure the agent** with the Workers URL in `relay_url`.

## Testing

```bash
# Test the relay directly
curl -X POST https://YOUR_RELAY_URL/ \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer your-secret" \
  -d '{"device_token":"test","title":"Test","body":"Hello"}'

# Test via the agent
TOKEN="your-marmy-auth-token"
curl -X POST http://localhost:9876/api/notifications/test \
  -H "Authorization: Bearer $TOKEN"
```

## Architecture

```
Phone (App Store)          Agent               Lambda/Worker          APNs
     │                       │                      │                  │
     ├─ register ────────────►│                      │                  │
     │  {token, provider:    │                      │                  │
     │   "relay"}            │                      │                  │
     │                       │                      │                  │
     │              Claude finishes task             │                  │
     │                       │                      │                  │
     │                       ├─ POST relay_url ─────►│                  │
     │                       │  {device_token,       ├─ HTTP/2 + JWT ──►│
     │                       │   title, body}        │                  │
     │◄──────────────────────┼──────────────────────┼──────── push ────┤
```
