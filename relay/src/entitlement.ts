// Entitlement check for relay credentials. The relay never knows who pays
// whom: it asks an entitlement service (any HTTPS endpoint sharing
// ENTITLEMENT_SECRET) whether a credential is active, or, for personal relays
// with no such service, consults a static allow-list of credential hashes.

export interface EntitlementEnv {
  ENTITLEMENT_URL?: string;
  ENTITLEMENT_SECRET?: string;
  /** Comma-separated SHA-256 hex hashes of relay credentials (self-host mode). */
  ENTITLEMENT_STATIC_KEYS?: string;
}

export interface Entitlement {
  active: boolean;
  /** unix seconds; 0 means "no end known" */
  periodEnd: number;
  /** supporter tier level from the entitlement service; 0 when unknown or self-hosted */
  level: number;
  /** tier name from the entitlement service, e.g. "recon" */
  tier: string | null;
  reason?: string;
}

const KEY_RE = /^PH-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$/;

export function normalizeKey(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const k = raw.trim().toUpperCase().replace(/\s+/g, "");
  return KEY_RE.test(k) ? k : null;
}

export async function sha256hex(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(d), (b) => b.toString(16).padStart(2, "0")).join("");
}

export async function checkEntitlement(env: EntitlementEnv, key: string, deviceId: string, platform: string, fetcher: typeof fetch = fetch): Promise<Entitlement> {
  if (env.ENTITLEMENT_URL && env.ENTITLEMENT_SECRET) {
    let resp: Response;
    try {
      resp = await fetcher(env.ENTITLEMENT_URL, {
        method: "POST",
        headers: { authorization: `Bearer ${env.ENTITLEMENT_SECRET}`, "content-type": "application/json" },
        body: JSON.stringify({ key, device_id: deviceId, platform }),
      });
    } catch {
      return { active: false, periodEnd: 0, level: 0, tier: null, reason: "entitlement service unreachable" };
    }
    if (resp.status === 404) return { active: false, periodEnd: 0, level: 0, tier: null, reason: "unknown credential" };
    if (resp.status === 429) return { active: false, periodEnd: 0, level: 0, tier: null, reason: "too many devices" };
    if (!resp.ok) return { active: false, periodEnd: 0, level: 0, tier: null, reason: `entitlement service ${resp.status}` };
    const j = (await resp.json()) as { active?: boolean; period_end?: string | number; level?: number; tier?: string | null; reason?: string };
    const pe = typeof j.period_end === "number" ? j.period_end : j.period_end ? Math.floor(Date.parse(j.period_end) / 1000) : 0;
    const level = typeof j.level === "number" && Number.isFinite(j.level) && j.level > 0 ? Math.floor(j.level) : 0;
    const tier = typeof j.tier === "string" && /^[a-z0-9-]{1,32}$/.test(j.tier) ? j.tier : null;
    return { active: j.active === true, periodEnd: Number.isFinite(pe) ? pe : 0, level, tier, reason: j.reason };
  }
  if (env.ENTITLEMENT_STATIC_KEYS) {
    const h = await sha256hex(key);
    const allowed = env.ENTITLEMENT_STATIC_KEYS.split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);
    return allowed.includes(h) ? { active: true, periodEnd: 0, level: 0, tier: null } : { active: false, periodEnd: 0, level: 0, tier: null, reason: "unknown credential" };
  }
  return { active: false, periodEnd: 0, level: 0, tier: null, reason: "no entitlement source configured" };
}
