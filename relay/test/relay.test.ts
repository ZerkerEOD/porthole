import { env } from "cloudflare:test";
import { describe, expect, it, beforeAll } from "vitest";
import { b64url, importSigningKey, importVerifyKey, publicFromPrivate, signGrant, verifyGrant, type GrantPayload } from "../src/grant";
import { handleGrant, handlePush, type Env } from "../src/index";
import { sha256hex } from "../src/entitlement";

let pkcs8 = "";
let testEnv: Env;

function fakeRate(ok = true) {
  return { limit: async () => ({ success: ok }) };
}

async function genKey(): Promise<string> {
  const kp = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  return b64url((await crypto.subtle.exportKey("pkcs8", kp.privateKey)) as ArrayBuffer);
}

let sa = "";

async function fakeServiceAccount(): Promise<string> {
  const kp = (await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const der = new Uint8Array((await crypto.subtle.exportKey("pkcs8", kp.privateKey)) as ArrayBuffer);
  let bin = "";
  for (const b of der) bin += String.fromCharCode(b);
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(bin).match(/.{1,64}/g)!.join("\n")}\n-----END PRIVATE KEY-----\n`;
  return JSON.stringify({ client_email: "x@y", private_key: pem, project_id: "p" });
}

beforeAll(async () => {
  pkcs8 = await genKey();
  sa = await fakeServiceAccount();
  testEnv = {
    ...(env as unknown as Env),
    GRANT_SIGNING_KEY: pkcs8,
    FCM_PROJECT_ID: "p",
    FCM_SERVICE_ACCOUNT: sa,
    ATTEST_MODE: "off",
    ANDROID_PACKAGE: "io.zerkersec.porthole",
    ENTITLEMENT_URL: "https://account.example/api/entitlement",
    ENTITLEMENT_SECRET: "shared-secret",
    PUSH_RATE: fakeRate(),
    GRANT_RATE: fakeRate(),
  };
});

async function mint(exp = Math.floor(Date.now() / 1000) + 3600, id = "device-aaaaaaaaaaaaaaaa"): Promise<string> {
  const key = await importSigningKey(pkcs8);
  const p: GrantPayload = { v: 1, d: id, t: "fcm-token-xxxxxxxxxxxxxxxxxxxxx", p: "android", iat: 0, exp };
  return signGrant(key, p);
}

function postPush(body: unknown): Request {
  return new Request("https://relay/v1/push", { method: "POST", body: JSON.stringify(body), headers: { "content-type": "application/json" } });
}

/** Fetch stub for Google OAuth + FCM. */
function googleStub(fcmStatus = 200): typeof fetch {
  return (async (input: RequestInfo | URL) => {
    const u = String(input instanceof Request ? input.url : input);
    if (u.startsWith("https://oauth2.googleapis.com/token")) return new Response(JSON.stringify({ access_token: "t", expires_in: 3600 }));
    if (u.includes("fcm.googleapis.com")) return new Response("{}", { status: fcmStatus });
    return new Response("nope", { status: 500 });
  }) as typeof fetch;
}

describe("grant", () => {
  it("round-trips and rejects tampering/expiry", async () => {
    const g = await mint();
    const vk = await importVerifyKey(await publicFromPrivate(pkcs8));
    expect(await verifyGrant(vk, g)).not.toBeNull();
    // Flip a byte in the middle of the signature (the final base64url char
    // carries padding bits a lenient decoder ignores).
    const dot = g.indexOf(".");
    const mid = dot + 20;
    const tampered = g.slice(0, mid) + (g[mid] === "A" ? "B" : "A") + g.slice(mid + 1);
    expect(await verifyGrant(vk, tampered)).toBeNull();
    const bodyTampered = g.slice(0, 5) + (g[5] === "A" ? "B" : "A") + g.slice(6);
    expect(await verifyGrant(vk, bodyTampered)).toBeNull();
    expect(await verifyGrant(vk, "nonsense")).toBeNull();
    const expired = await mint(Math.floor(Date.now() / 1000) - 1);
    expect(await verifyGrant(vk, expired)).toBeNull();
    const other = await genKey();
    const foreign = await signGrant(await importSigningKey(other), { v: 1, d: "d", t: "t", p: "ios", iat: 0, exp: 9e9 });
    expect(await verifyGrant(vk, foreign)).toBeNull();
  });
});

describe("push", () => {
  it("accepts a valid grant and forwards to FCM with the grant's token", async () => {
    let sent: any = null;
    const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const u = String(input);
      if (u.includes("oauth2")) return new Response(JSON.stringify({ access_token: "t", expires_in: 3600 }));
      if (u.includes("fcm.googleapis.com")) {
        sent = JSON.parse(String(init?.body));
        return new Response("{}");
      }
      return new Response("x", { status: 500 });
    }) as typeof fetch;
    const r = await handlePush(postPush({ grant: await mint(), ct: "QUJD", collapse: "claude:abc" }), testEnv, fetcher);
    expect(r.status).toBe(202);
    expect(sent.message.token).toBe("fcm-token-xxxxxxxxxxxxxxxxxxxxx");
    expect(sent.message.data.ct).toBe("QUJD");
    expect(sent.message.apns.payload.aps.alert.body).not.toContain("QUJD");
  });
  it("ignores a caller-supplied token and rejects bad grants", async () => {
    const r = await handlePush(postPush({ grant: "bad.grant", ct: "QUJD", token: "attacker" }), testEnv, googleStub());
    expect(r.status).toBe(401);
  });
  it("rejects oversized ciphertext", async () => {
    const big = "A".repeat(2000);
    const r = await handlePush(postPush({ grant: await mint(), ct: big }), testEnv, googleStub());
    expect(r.status).toBe(400);
  });
  it("honours the deny list", async () => {
    await testEnv.DENY.put("device-bbbbbbbbbbbbbbbb", "1");
    const r = await handlePush(postPush({ grant: await mint(undefined, "device-bbbbbbbbbbbbbbbb"), ct: "QUJD" }), testEnv, googleStub());
    expect(r.status).toBe(403);
  });
  it("trips the rate limiter", async () => {
    const limited = { ...testEnv, PUSH_RATE: fakeRate(false) };
    const r = await handlePush(postPush({ grant: await mint(), ct: "QUJD" }), limited, googleStub());
    expect(r.status).toBe(429);
  });
  it("maps a dead FCM token to 410 so the daemon drops the grant", async () => {
    const r = await handlePush(postPush({ grant: await mint(undefined, "device-cccccccccccccccc"), ct: "QUJD" }), testEnv, googleStub(404));
    expect(r.status).toBe(410);
  });
});

describe("grant endpoint", () => {
  const goodKey = "PH-7K3M-Q9ZD-X2VH-R8TB";
  /** The store app sends the credential as a Bearer header. */
  function grantReq(key: unknown, id = "device-dddddddddddddddd"): Request {
    const headers: Record<string, string> = { "content-type": "application/json" };
    if (typeof key === "string") headers.authorization = `Bearer ${key}`;
    return new Request("https://relay/v1/grant", { method: "POST", headers, body: JSON.stringify({ device_id: id, platform: "android", push_token: "fcm-token-xxxxxxxxxxxxxxxxxxxxx" }) });
  }
  /** Self-built apps may still send it in the body. */
  function grantReqBody(key: unknown, id = "device-dddddddddddddddd"): Request {
    return new Request("https://relay/v1/grant", { method: "POST", body: JSON.stringify({ device_id: id, platform: "android", push_token: "fcm-token-xxxxxxxxxxxxxxxxxxxxx", supporter_key: key }) });
  }
  /** Entitlement service stub: records the request, answers per key. */
  function entitlementStub(answer: (body: any) => Response, seen: any[] = []): typeof fetch {
    return (async (input: RequestInfo | URL, init?: RequestInit) => {
      const u = String(input);
      if (u.startsWith("https://account.example/api/entitlement")) {
        const body = JSON.parse(String(init?.body));
        seen.push({ body, auth: (init?.headers as Record<string, string>)["authorization"] });
        return answer(body);
      }
      if (u.includes("oauth2")) return new Response(JSON.stringify({ access_token: "t", expires_in: 3600 }));
      if (u.includes("fcm.googleapis.com")) return new Response("{}");
      return new Response("x", { status: 500 });
    }) as typeof fetch;
  }

  it("refuses a malformed key without calling the service", async () => {
    const seen: any[] = [];
    const r = await handleGrant(grantReq("not-a-key"), testEnv, entitlementStub(() => new Response("{}"), seen));
    expect(r.status).toBe(400);
    expect(seen.length).toBe(0);
  });
  it("accepts the credential in the body for self-built apps", async () => {
    const seen: any[] = [];
    const r = await handleGrant(grantReqBody(goodKey), testEnv, entitlementStub(() => new Response(JSON.stringify({ active: true })), seen));
    expect(r.status).toBe(200);
    expect(seen[0].body.key).toBe(goodKey);
  });
  it("refuses a request with no credential at all", async () => {
    const seen: any[] = [];
    const r = await handleGrant(grantReqBody(undefined), testEnv, entitlementStub(() => new Response("{}"), seen));
    expect(r.status).toBe(400);
    expect(((await r.json()) as any).error).toBe("relay credential format");
    expect(seen.length).toBe(0);
  });
  it("refuses when the service says inactive", async () => {
    const r = await handleGrant(grantReq(goodKey), testEnv, entitlementStub(() => new Response(JSON.stringify({ active: false, reason: "lapsed" }))));
    expect(r.status).toBe(402);
    expect(((await r.json()) as any).error).toContain("lapsed");
  });
  it("refuses when the service is unreachable", async () => {
    const fetcher = (async () => { throw new Error("boom"); }) as unknown as typeof fetch;
    const r = await handleGrant(grantReq(goodKey), testEnv, fetcher);
    expect(r.status).toBe(402);
  });
  it("mints a grant capped at 30 days and bound to the device, sending the shared secret", async () => {
    const seen: any[] = [];
    const far = new Date(Date.now() + 400 * 86400 * 1000).toISOString();
    const r = await handleGrant(grantReq(" ph-7k3m-q9zd-x2vh-r8tb ", "device-eeeeeeeeeeeeeeee"), testEnv, entitlementStub(() => new Response(JSON.stringify({ active: true, period_end: far })), seen));
    expect(r.status).toBe(200);
    expect(seen[0].auth).toBe("Bearer shared-secret");
    expect(seen[0].body.key).toBe(goodKey); // normalised before it leaves the relay
    expect(seen[0].body.device_id).toBe("device-eeeeeeeeeeeeeeee");
    const j = (await r.json()) as { grant: string; expires_at: string };
    const days = (Date.parse(j.expires_at) - Date.now()) / 86400000;
    expect(days).toBeLessThanOrEqual(30.01);
    expect(days).toBeGreaterThan(29);
    const push = await handlePush(postPush({ grant: j.grant, ct: "QUJD" }), testEnv, googleStub());
    expect(push.status).toBe(202);
  });
  it("uses the period end when it is sooner than 30 days", async () => {
    const soon = new Date(Date.now() + 3 * 86400 * 1000).toISOString();
    const r = await handleGrant(grantReq(goodKey), testEnv, entitlementStub(() => new Response(JSON.stringify({ active: true, period_end: soon }))));
    const j = (await r.json()) as { expires_at: string };
    const days = (Date.parse(j.expires_at) - Date.now()) / 86400000;
    expect(days).toBeLessThanOrEqual(3.01);
  });
  it("maps a device-cap answer to a refusal", async () => {
    const r = await handleGrant(grantReq(goodKey), testEnv, entitlementStub(() => new Response("{}", { status: 429 })));
    expect(r.status).toBe(402);
    expect(((await r.json()) as any).error).toContain("devices");
  });
  it("static allow-list mode works for personal relays", async () => {
    const h = await sha256hex(goodKey);
    const env = { ...testEnv, ENTITLEMENT_URL: "", ENTITLEMENT_SECRET: "", ENTITLEMENT_STATIC_KEYS: ` ${h.toUpperCase()} ,deadbeef` };
    const ok = await handleGrant(grantReq(goodKey), env, googleStub());
    expect(ok.status).toBe(200);
    const no = await handleGrant(grantReq("PH-AAAA-BBBB-CCCC-DDDD"), env, googleStub());
    expect(no.status).toBe(402);
  });
  it("refuses when no entitlement source is configured", async () => {
    const env = { ...testEnv, ENTITLEMENT_URL: "", ENTITLEMENT_SECRET: "" };
    const r = await handleGrant(grantReq(goodKey), env, googleStub());
    expect(r.status).toBe(402);
  });
});
