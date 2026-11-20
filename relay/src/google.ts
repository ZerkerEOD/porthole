// Google OAuth for service accounts (FCM, Play Integrity),
// signed with WebCrypto. Tokens are cached per isolate.

import { b64url } from "./grant";

interface ServiceAccount {
  client_email: string;
  private_key: string; // PEM
  project_id?: string;
}

const cache = new Map<string, { token: string; exp: number }>();

function pemToDer(pem: string): ArrayBuffer {
  const b = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const bin = atob(b);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out.buffer;
}

export async function accessToken(saJSON: string, scope: string, fetcher: typeof fetch = fetch): Promise<string> {
  const sa = JSON.parse(saJSON) as ServiceAccount;
  const k = `${sa.client_email}|${scope}`;
  const now = Math.floor(Date.now() / 1000);
  const hit = cache.get(k);
  if (hit && hit.exp - 60 > now) return hit.token;
  const key = await crypto.subtle.importKey("pkcs8", pemToDer(sa.private_key), { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const enc = new TextEncoder();
  const header = b64url(enc.encode(JSON.stringify({ alg: "RS256", typ: "JWT" })));
  const claims = b64url(enc.encode(JSON.stringify({ iss: sa.client_email, scope, aud: "https://oauth2.googleapis.com/token", iat: now, exp: now + 3600 })));
  const sig = b64url(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, enc.encode(`${header}.${claims}`)));
  const resp = await fetcher("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: `${header}.${claims}.${sig}` }),
  });
  if (!resp.ok) throw new Error(`google oauth ${resp.status}`);
  const j = (await resp.json()) as { access_token: string; expires_in: number };
  cache.set(k, { token: j.access_token, exp: now + j.expires_in });
  return j.access_token;
}

export function projectIdOf(saJSON: string): string {
  try {
    return (JSON.parse(saJSON) as ServiceAccount).project_id ?? "";
  } catch {
    return "";
  }
}
