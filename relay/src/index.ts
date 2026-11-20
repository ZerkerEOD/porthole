// Porthole push relay.
//
//   POST /v1/grant  {device_id, platform, push_token, attestation?}
//                   Authorization: Bearer <relay credential>
//                   (self-host builds may send the credential as body.supporter_key)
//                   -> {grant, expires_at, level, tier}
//   POST /v1/push   {grant, ct, collapse?}  -> 202
//   GET  /v1/pubkey -> {spki} (so self-hosters can inspect their key)
//
// The relay holds no subscriber list. A grant proves that a relay credential
// (the key in the user's relay URL) was active at mint time, bound to one
// push token; pushes are rate limited
// per device id and can be blocked by writing the device id into the DENY
// KV namespace. Who is a supporter is decided by the entitlement service
// (src/entitlement.ts), never here.

import { GrantPayload, importSigningKey, importVerifyKey, publicFromPrivate, signGrant, verifyGrant } from "./grant";
import { accessToken, projectIdOf } from "./google";
import { checkEntitlement, EntitlementEnv, normalizeKey } from "./entitlement";

export interface Env extends EntitlementEnv {
  FCM_SERVICE_ACCOUNT?: string;
  ANDROID_PACKAGE: string;
  GRANT_SIGNING_KEY: string; // Ed25519 PKCS8 base64url
  GRANT_VERIFY_KEY?: string; // optional SPKI; derived from the private key when absent
  FCM_PROJECT_ID: string;
  ATTEST_MODE: string; // off | android | all
  DENY: KVNamespace;
  PUSH_RATE: { limit: (opts: { key: string }) => Promise<{ success: boolean }> };
  GRANT_RATE: { limit: (opts: { key: string }) => Promise<{ success: boolean }> };
}

const MAX_CT = 480; // bytes of ciphertext, before base64
const MAX_GRANT_DAYS = 30;
const DAILY_CAP = 300;

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });
}

async function readJSON(req: Request, max: number): Promise<Record<string, unknown> | null> {
  const len = Number(req.headers.get("content-length") ?? "0");
  if (len > max) return null;
  const text = await req.text();
  if (text.length > max) return null;
  try {
    const v = JSON.parse(text);
    return v && typeof v === "object" ? (v as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

let verifyKeyCache: { src: string; key: CryptoKey } | null = null;
async function verifyKey(env: Env): Promise<CryptoKey> {
  const spki = env.GRANT_VERIFY_KEY || (await publicFromPrivate(env.GRANT_SIGNING_KEY));
  if (verifyKeyCache && verifyKeyCache.src === spki) return verifyKeyCache.key;
  const key = await importVerifyKey(spki);
  verifyKeyCache = { src: spki, key };
  return key;
}

/** The relay credential from `Authorization: Bearer <credential>`, if present. */
function bearer(req: Request): string | null {
  const h = req.headers.get("authorization") ?? "";
  const m = /^Bearer\s+(.{1,128})$/i.exec(h.trim());
  return m ? m[1] : null;
}

function clientIP(req: Request): string {
  return req.headers.get("cf-connecting-ip") ?? "0.0.0.0";
}

export async function handleGrant(req: Request, env: Env, fetcher: typeof fetch = fetch): Promise<Response> {
  if (!(await env.GRANT_RATE.limit({ key: clientIP(req) })).success) return json(429, { error: "slow down" });
  const b = await readJSON(req, 16 * 1024);
  if (!b) return json(400, { error: "bad request" });
  const deviceId = String(b.device_id ?? "");
  const platform = b.platform === "ios" ? "ios" : b.platform === "android" ? "android" : null;
  const pushToken = String(b.push_token ?? "");
  const key = normalizeKey(bearer(req) ?? b.supporter_key);
  if (!/^[A-Za-z0-9_-]{16,64}$/.test(deviceId) || !platform || pushToken.length < 20 || pushToken.length > 4096) {
    return json(400, { error: "bad request" });
  }
  if (!key) return json(400, { error: "relay credential format" });
  if (await env.DENY.get(deviceId)) return json(403, { error: "device blocked" });
  if (env.ATTEST_MODE !== "off" && (env.ATTEST_MODE === "all" || platform === "android")) {
    // Platform attestation hook. Play Integrity decodeIntegrityToken /
    // App Attest verification plug in here; until configured, refuse rather
    // than silently skip.
    const att = b.attestation as { token?: string } | undefined;
    if (!att?.token) return json(403, { error: "attestation required" });
    const ok = await verifyAttestation(env, platform, att.token, fetcher);
    if (!ok) return json(403, { error: "attestation failed" });
  }
  const ent = await checkEntitlement(env, key, deviceId, platform, fetcher);
  if (!ent.active) return json(402, { error: ent.reason ?? "relay access not active" });
  const now = Math.floor(Date.now() / 1000);
  const cap = now + MAX_GRANT_DAYS * 86400;
  const exp = ent.periodEnd > 0 ? Math.min(ent.periodEnd, cap) : cap;
  if (exp <= now) return json(402, { error: "relay access period ended" });
  const payload: GrantPayload = { v: 1, d: deviceId, t: pushToken, p: platform, iat: now, exp };
  const grant = await signGrant(await importSigningKey(env.GRANT_SIGNING_KEY), payload);
  return json(200, { grant, expires_at: new Date(payload.exp * 1000).toISOString(), level: ent.level, tier: ent.tier });
}

async function verifyAttestation(env: Env, platform: string, token: string, fetcher: typeof fetch): Promise<boolean> {
  if (platform === "android" && env.FCM_SERVICE_ACCOUNT) {
    try {
      const tok = await accessToken(env.FCM_SERVICE_ACCOUNT, "https://www.googleapis.com/auth/playintegrity", fetcher);
      const resp = await fetcher(`https://playintegrity.googleapis.com/v1/${encodeURIComponent(env.ANDROID_PACKAGE)}:decodeIntegrityToken`, {
        method: "POST",
        headers: { authorization: `Bearer ${tok}`, "content-type": "application/json" },
        body: JSON.stringify({ integrity_token: token }),
      });
      if (!resp.ok) return false;
      const j = (await resp.json()) as { tokenPayloadExternal?: { appIntegrity?: { appRecognitionVerdict?: string }; deviceIntegrity?: { deviceRecognitionVerdict?: string[] } } };
      const p = j.tokenPayloadExternal;
      return p?.appIntegrity?.appRecognitionVerdict === "PLAY_RECOGNIZED" && (p?.deviceIntegrity?.deviceRecognitionVerdict ?? []).includes("MEETS_DEVICE_INTEGRITY");
    } catch {
      return false;
    }
  }
  // iOS App Attest verification is not implemented in this version.
  return false;
}

export async function handlePush(req: Request, env: Env, fetcher: typeof fetch = fetch): Promise<Response> {
  const b = await readJSON(req, 4096);
  if (!b) return json(400, { error: "bad request" });
  const grant = String(b.grant ?? "");
  const ct = String(b.ct ?? "");
  const collapse = String(b.collapse ?? "").slice(0, 64);
  if (!grant || !ct || !/^[A-Za-z0-9_-]+$/.test(ct) || Math.floor((ct.length * 3) / 4) > MAX_CT) return json(400, { error: "bad request" });
  const p = await verifyGrant(await verifyKey(env), grant);
  if (!p) return json(401, { error: "invalid grant" });
  if (await env.DENY.get(p.d)) return json(403, { error: "device blocked" });
  if (!(await env.PUSH_RATE.limit({ key: p.d })).success) return json(429, { error: "rate limited" });
  // Daily cap, eventually consistent, per device.
  const day = new Date().toISOString().slice(0, 10);
  const capKey = `cap:${p.d}:${day}`;
  const used = Number((await env.DENY.get(capKey)) ?? "0");
  if (used >= DAILY_CAP) return json(429, { error: "daily cap" });
  await env.DENY.put(capKey, String(used + 1), { expirationTtl: 2 * 86400 });

  const projectId = env.FCM_PROJECT_ID || projectIdOf(env.FCM_SERVICE_ACCOUNT ?? "");
  if (!env.FCM_SERVICE_ACCOUNT || !projectId) return json(503, { error: "fcm not configured" });
  const tok = await accessToken(env.FCM_SERVICE_ACCOUNT, "https://www.googleapis.com/auth/firebase.messaging", fetcher);
  const message: Record<string, unknown> = {
    token: p.t,
    data: { ct, v: "1" },
    android: { priority: "high", ttl: "600s", ...(collapse ? { collapse_key: collapse.replace(/[^A-Za-z0-9_-]/g, "_").slice(0, 32) } : {}) },
    apns: {
      headers: { "apns-priority": "10", "apns-push-type": "alert", ...(collapse ? { "apns-collapse-id": collapse.slice(0, 64) } : {}) },
      payload: {
        aps: {
          // Generic text by design: the real content is in `ct` and is
          // decrypted on the device (a notification service extension can
          // rewrite the alert once it has the key).
          alert: { title: "Porthole", body: "A session needs your attention" },
          sound: "default",
          "mutable-content": 1,
          "thread-id": collapse || "porthole",
        },
      },
    },
  };
  const resp = await fetcher(`https://fcm.googleapis.com/v1/projects/${encodeURIComponent(projectId)}/messages:send`, {
    method: "POST",
    headers: { authorization: `Bearer ${tok}`, "content-type": "application/json" },
    body: JSON.stringify({ message }),
  });
  if (resp.status === 404 || resp.status === 400) {
    // Token no longer valid: tell the daemon to drop the grant.
    return json(410, { error: "push token gone" });
  }
  if (!resp.ok) return json(502, { error: `fcm ${resp.status}` });
  return json(202, { ok: true });
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (req.method === "POST" && url.pathname === "/v1/grant") return handleGrant(req, env);
    if (req.method === "POST" && url.pathname === "/v1/push") return handlePush(req, env);
    if (req.method === "GET" && url.pathname === "/v1/pubkey") {
      return json(200, { spki: env.GRANT_VERIFY_KEY || (await publicFromPrivate(env.GRANT_SIGNING_KEY)) });
    }
    if (req.method === "GET" && url.pathname === "/") return new Response("porthole relay", { headers: { "cache-control": "no-store" } });
    return json(404, { error: "not found" });
  },
};
