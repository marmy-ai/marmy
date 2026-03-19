/**
 * Marmy Push Relay — Cloudflare Workers version.
 *
 * Uses the Web Crypto API instead of Node.js crypto for ES256 signing.
 * Configure environment variables via wrangler.toml or the Workers dashboard.
 */

// --- JWT generation (ES256 via Web Crypto, cached 50 minutes) ---

let cachedJwt = null;
let cachedJwtTime = 0;

async function getJwt(env) {
  const now = Math.floor(Date.now() / 1000);
  if (cachedJwt && now - cachedJwtTime < 50 * 60) {
    return cachedJwt;
  }

  const keyPem = atob(env.APNS_KEY_BASE64);
  const pemBody = keyPem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s/g, "");

  const keyData = Uint8Array.from(atob(pemBody), (c) => c.charCodeAt(0));

  const key = await crypto.subtle.importKey(
    "pkcs8",
    keyData,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );

  const header = btoa(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID }))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");

  const claims = btoa(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: now }))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");

  const signingInput = new TextEncoder().encode(`${header}.${claims}`);
  const signatureBuffer = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    signingInput
  );

  // Convert DER signature to raw r||s format expected by JWT
  const signature = btoa(String.fromCharCode(...new Uint8Array(signatureBuffer)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");

  cachedJwt = `${header}.${claims}.${signature}`;
  cachedJwtTime = now;
  return cachedJwt;
}

// --- Worker fetch handler ---

export default {
  async fetch(request, env) {
    if (request.method !== "POST") {
      return new Response("method not allowed", { status: 405 });
    }

    // Optional auth
    if (env.RELAY_SECRET) {
      const auth = request.headers.get("authorization") || "";
      if (auth !== `Bearer ${env.RELAY_SECRET}`) {
        return new Response("unauthorized", { status: 401 });
      }
    }

    const body = await request.json().catch(() => null);
    if (!body?.device_token) {
      return new Response("missing device_token", { status: 400 });
    }

    if (!env.APNS_KEY_BASE64 || !env.APNS_KEY_ID || !env.APNS_TEAM_ID) {
      return new Response("APNs not configured", { status: 500 });
    }

    const topic = env.APNS_TOPIC || "com.marmy.app";
    const sandbox = env.APNS_SANDBOX === "true";
    const host = sandbox
      ? "api.sandbox.push.apple.com"
      : "api.push.apple.com";

    const jwt = await getJwt(env);

    const payload = JSON.stringify({
      aps: {
        alert: {
          title: body.title || "Session",
          body: body.body || "Task complete",
        },
        sound: "default",
      },
      session_name: body.session_name || "",
      event: "task_complete",
    });

    const resp = await fetch(`https://${host}/3/device/${body.device_token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": topic,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "content-type": "application/json",
      },
      body: payload,
    });

    if (resp.ok) {
      return new Response("sent", { status: 200 });
    }

    const text = await resp.text();
    return new Response(`APNs ${resp.status}: ${text}`, { status: 502 });
  },
};
