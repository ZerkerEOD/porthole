// Push grants: a signed, short-lived statement that a specific device
// (push token) may be pushed to. Minted only after the entitlement check;
// verified statelessly on every push.

export interface GrantPayload {
  v: 1;
  d: string; // device id (random, chosen by the app)
  t: string; // FCM registration token
  p: "ios" | "android";
  iat: number; // unix seconds
  exp: number;
}

const enc = new TextEncoder();

export function b64url(bytes: ArrayBuffer | Uint8Array): string {
  const u = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let s = "";
  for (const b of u) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function unb64url(s: string): Uint8Array {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + pad);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export async function importSigningKey(pkcs8b64: string): Promise<CryptoKey> {
  return crypto.subtle.importKey("pkcs8", unb64url(pkcs8b64.replace(/\s+/g, "")), { name: "Ed25519" }, false, ["sign"]);
}

export async function importVerifyKey(spkib64: string): Promise<CryptoKey> {
  return crypto.subtle.importKey("spki", unb64url(spkib64.replace(/\s+/g, "")), { name: "Ed25519" }, false, ["verify"]);
}

/** Derives the public (SPKI) key for a PKCS8 Ed25519 private key. */
export async function publicFromPrivate(pkcs8b64: string): Promise<string> {
  const raw = unb64url(pkcs8b64.replace(/\s+/g, ""));
  // PKCS8 Ed25519: 16-byte header, then OCTET STRING(OCTET STRING(32-byte seed)).
  const seed = raw.slice(raw.length - 32);
  const priv = await crypto.subtle.importKey("pkcs8", raw, { name: "Ed25519" }, true, ["sign"]);
  void seed;
  const jwk = (await crypto.subtle.exportKey("jwk", priv)) as JsonWebKey;
  const pub = await crypto.subtle.importKey("jwk", { kty: "OKP", crv: "Ed25519", x: jwk.x }, { name: "Ed25519" }, true, ["verify"]);
  return b64url((await crypto.subtle.exportKey("spki", pub)) as ArrayBuffer);
}

export async function signGrant(key: CryptoKey, payload: GrantPayload): Promise<string> {
  const body = b64url(enc.encode(JSON.stringify(payload)));
  const sig = await crypto.subtle.sign({ name: "Ed25519" }, key, enc.encode(body));
  return `${body}.${b64url(sig)}`;
}

export async function verifyGrant(key: CryptoKey, grant: string, now = Math.floor(Date.now() / 1000)): Promise<GrantPayload | null> {
  if (typeof grant !== "string" || grant.length > 2048) return null;
  const dot = grant.indexOf(".");
  if (dot <= 0) return null;
  const body = grant.slice(0, dot);
  const sig = grant.slice(dot + 1);
  let ok = false;
  try {
    ok = await crypto.subtle.verify({ name: "Ed25519" }, key, unb64url(sig), enc.encode(body));
  } catch {
    return null;
  }
  if (!ok) return null;
  let p: GrantPayload;
  try {
    p = JSON.parse(new TextDecoder().decode(unb64url(body)));
  } catch {
    return null;
  }
  if (p.v !== 1 || typeof p.d !== "string" || typeof p.t !== "string" || typeof p.exp !== "number") return null;
  if (p.exp <= now) return null;
  return p;
}
