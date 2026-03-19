/**
 * Marmy Push Relay — forwards push notifications to APNs on behalf of
 * App Store builds that don't have their own p8 key.
 *
 * Receives: { device_token, title, body, session_name }
 * Authenticates with APNs using a p8 key from environment config.
 * Forwards to APNs HTTP/2 endpoint.
 *
 * Deployable as: AWS Lambda (via function URL or API Gateway),
 * Cloudflare Worker, or any Node.js 18+ runtime.
 */

import http2 from "node:http2";
import crypto from "node:crypto";

// --- Configuration (from environment variables) ---

const APNS_KEY_BASE64 = process.env.APNS_KEY_BASE64; // p8 key, base64-encoded
const APNS_KEY_ID = process.env.APNS_KEY_ID; // 10-char Key ID
const APNS_TEAM_ID = process.env.APNS_TEAM_ID; // Apple Team ID
const APNS_TOPIC = process.env.APNS_TOPIC || "com.marmy.app";
const APNS_SANDBOX = process.env.APNS_SANDBOX === "true";
const RELAY_SECRET = process.env.RELAY_SECRET || ""; // optional shared secret

const APNS_HOST = APNS_SANDBOX
  ? "api.sandbox.push.apple.com"
  : "api.push.apple.com";

// --- JWT generation (ES256, cached for 50 minutes) ---

let cachedJwt = null;
let cachedJwtTime = 0;

function getJwt() {
  const now = Math.floor(Date.now() / 1000);
  if (cachedJwt && now - cachedJwtTime < 50 * 60) {
    return cachedJwt;
  }

  const key = Buffer.from(APNS_KEY_BASE64, "base64").toString("utf8");

  const header = Buffer.from(
    JSON.stringify({ alg: "ES256", kid: APNS_KEY_ID })
  ).toString("base64url");

  const claims = Buffer.from(
    JSON.stringify({ iss: APNS_TEAM_ID, iat: now })
  ).toString("base64url");

  const signer = crypto.createSign("SHA256");
  signer.update(`${header}.${claims}`);
  const signature = signer.sign(key, "base64url");

  cachedJwt = `${header}.${claims}.${signature}`;
  cachedJwtTime = now;
  return cachedJwt;
}

// --- APNs HTTP/2 push ---

function sendPush(deviceToken, title, body, sessionName) {
  return new Promise((resolve, reject) => {
    const jwt = getJwt();
    const client = http2.connect(`https://${APNS_HOST}`);

    const payload = JSON.stringify({
      aps: {
        alert: { title, body },
        sound: "default",
      },
      session_name: sessionName,
      event: "task_complete",
    });

    const req = client.request({
      ":method": "POST",
      ":path": `/3/device/${deviceToken}`,
      authorization: `bearer ${jwt}`,
      "apns-topic": APNS_TOPIC,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
      "content-length": Buffer.byteLength(payload),
    });

    let responseData = "";
    let statusCode = 0;

    req.on("response", (headers) => {
      statusCode = headers[":status"];
    });

    req.on("data", (chunk) => {
      responseData += chunk;
    });

    req.on("end", () => {
      client.close();
      if (statusCode === 200) {
        resolve({ statusCode: 200, body: "ok" });
      } else {
        reject(new Error(`APNs ${statusCode}: ${responseData}`));
      }
    });

    req.on("error", (err) => {
      client.close();
      reject(err);
    });

    req.write(payload);
    req.end();
  });
}

// --- Lambda handler ---

export async function handler(event) {
  // Parse body (Lambda function URL sends raw body, API Gateway may wrap it)
  let body;
  if (typeof event.body === "string") {
    body = JSON.parse(event.body);
  } else if (event.device_token) {
    body = event;
  } else {
    return { statusCode: 400, body: "missing body" };
  }

  // Optional auth
  if (RELAY_SECRET) {
    const authHeader =
      event.headers?.authorization || event.headers?.Authorization || "";
    if (authHeader !== `Bearer ${RELAY_SECRET}`) {
      return { statusCode: 401, body: "unauthorized" };
    }
  }

  const { device_token, title, body: msg, session_name } = body;

  if (!device_token) {
    return { statusCode: 400, body: "missing device_token" };
  }

  if (!APNS_KEY_BASE64 || !APNS_KEY_ID || !APNS_TEAM_ID) {
    return { statusCode: 500, body: "APNs not configured" };
  }

  try {
    await sendPush(
      device_token,
      title || "Session",
      msg || "Task complete",
      session_name || ""
    );
    return { statusCode: 200, body: "sent" };
  } catch (err) {
    console.error("APNs error:", err.message);
    return { statusCode: 502, body: err.message };
  }
}
