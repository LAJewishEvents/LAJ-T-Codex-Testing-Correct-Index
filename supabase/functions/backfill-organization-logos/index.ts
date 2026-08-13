import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const BUCKET = "organization-logos";
const MAX_IMAGE_BYTES = 5 * 1024 * 1024;
const IMAGE_TYPES = new Map([
  ["image/png", "png"], ["image/jpeg", "jpg"], ["image/webp", "webp"],
  ["image/gif", "gif"], ["image/svg+xml", "svg"],
]);

function absoluteUrl(value: string | null | undefined, base?: string) {
  if (!value) return null;
  try {
    const url = new URL(value.trim(), base);
    return /^https?:$/.test(url.protocol) ? url.href : null;
  } catch { return null; }
}

function attr(tag: string, name: string) {
  const match = tag.match(new RegExp(`${name}\\s*=\\s*["']([^"']+)["']`, "i"));
  return match?.[1] || null;
}

function discoverCandidates(html: string, website: string) {
  const candidates: Array<{ url: string; kind: string; score: number }> = [];
  for (const tag of html.match(/<(?:meta|link|img)\b[^>]*>/gi) || []) {
    const property = (attr(tag, "property") || attr(tag, "name") || "").toLowerCase();
    const rel = (attr(tag, "rel") || "").toLowerCase();
    const itemprop = (attr(tag, "itemprop") || "").toLowerCase();
    const descriptor = `${attr(tag, "class") || ""} ${attr(tag, "id") || ""} ${attr(tag, "alt") || ""}`.toLowerCase();
    const raw = tag.startsWith("<meta") ? attr(tag, "content") : attr(tag, "href") || attr(tag, "src");
    const url = absoluteUrl(raw, website);
    if (!url) continue;
    if (/logo/.test(itemprop) || /logo|brand/.test(descriptor)) candidates.push({ url, kind: "official website logo", score: 100 });
    else if (property === "og:image" || property === "twitter:image") candidates.push({ url, kind: property, score: 80 });
    else if (rel.includes("apple-touch-icon")) candidates.push({ url, kind: "apple-touch-icon", score: 70 });
    else if (rel.includes("icon")) candidates.push({ url, kind: "favicon", score: 60 });
  }
  const favicon = absoluteUrl("/favicon.ico", website);
  if (favicon) candidates.push({ url: favicon, kind: "favicon", score: 40 });
  return [...new Map(candidates.sort((a, b) => b.score - a.score).map(c => [c.url, c])).values()];
}

function websiteFromEvents(events: Array<{ event_url?: string }> | null) {
  const nonOfficialHosts = /(^|\.)(eventbrite|facebook|instagram|meetup|partiful|lu\.ma|zoom|google|jewishla)\./i;
  for (const event of events || []) {
    const candidate = absoluteUrl(event.event_url);
    if (candidate && !nonOfficialHosts.test(new URL(candidate).hostname)) return new URL(candidate).origin;
  }
  return null;
}

async function downloadImage(candidate: { url: string; kind: string }) {
  const response = await fetch(candidate.url, { redirect: "follow", headers: { "user-agent": "LAJewishTonightLogoBot/1.0" } });
  if (!response.ok) throw new Error(`image HTTP ${response.status}`);
  const type = (response.headers.get("content-type") || "").split(";")[0].toLowerCase();
  const extension = IMAGE_TYPES.get(type);
  if (!extension) throw new Error(`not a supported image (${type || "unknown content type"})`);
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (!bytes.length || bytes.length > MAX_IMAGE_BYTES) throw new Error(`invalid image size ${bytes.length}`);
  return { bytes, type, extension };
}

Deno.serve(async request => {
  const suppliedSecret = request.headers.get("x-backfill-secret");
  const expectedSecret = Deno.env.get("ORGANIZATION_LOGO_BACKFILL_SECRET");
  if (!expectedSecret || suppliedSecret !== expectedSecret) return new Response("Unauthorized", { status: 401 });
  const url = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const supabase = createClient(url, serviceKey, { auth: { persistSession: false } });
  const body = request.method === "POST" ? await request.json().catch(() => ({})) : {};
  const limit = Math.min(Math.max(Number(body.limit) || 100, 1), 500);
  const force = body.force === true;
  let query = supabase.from("organizations").select("id,name,slug,logo_url,website_url,logo_source,logo_storage_path,organization_events(event_url)").order("name").limit(limit);
  if (typeof body.organization === "string" && body.organization.trim()) {
    query = query.ilike("name", body.organization.trim());
  }
  if (!force) query = query.is("logo_storage_path", null);
  const { data: organizations, error } = await query;
  if (error) return Response.json({ error: error.message }, { status: 500 });
  const results = [];
  for (const organization of organizations || []) {
    const log = { organization: organization.name, website: organization.website_url, status: "fallback", reason: "", logo_url: null as string | null };
    try {
      if (organization.logo_storage_path && !force) { log.status = "cached"; results.push(log); continue; }
      const explicit = absoluteUrl(organization.logo_source);
      const website = absoluteUrl(organization.website_url) || websiteFromEvents(organization.organization_events);
      let canonicalWebsite = website;
      let candidates = explicit ? [{ url: explicit, kind: "existing explicit logo", score: 200 }] : [];
      if (!candidates.length) {
        if (!website) throw new Error("no verified official website_url or explicit logo source");
        console.log("organization logo discovery", { organization: organization.name, website });
        const page = await fetch(website, { redirect: "follow", headers: { "user-agent": "LAJewishTonightLogoBot/1.0" } });
        if (!page.ok) throw new Error(`website HTTP ${page.status}`);
        canonicalWebsite = page.url;
        candidates = discoverCandidates(await page.text(), page.url);
      }
      let uploaded = false;
      const failures = [];
      for (const candidate of candidates) {
        try {
          console.log("organization logo candidate", { organization: organization.name, source: candidate.url, kind: candidate.kind });
          const image = await downloadImage(candidate);
          const path = `${organization.slug || organization.id}/logo.${image.extension}`;
          const upload = await supabase.storage.from(BUCKET).upload(path, image.bytes, { contentType: image.type, upsert: true, cacheControl: "31536000" });
          if (upload.error) throw upload.error;
          const logoUrl = supabase.storage.from(BUCKET).getPublicUrl(path).data.publicUrl;
          const update = { logo_url: logoUrl, logo_source: candidate.url, logo_storage_path: path, logo_updated_at: new Date().toISOString(), ...(canonicalWebsite ? { website_url: canonicalWebsite } : {}) };
          const saved = await supabase.from("organizations").update(update).eq("id", organization.id);
          if (saved.error) throw saved.error;
          Object.assign(log, { status: "saved", logo_url: logoUrl, reason: "" });
          console.log("organization logo saved", { organization: organization.name, source: candidate.url, path, logo_url: logoUrl });
          uploaded = true; break;
        } catch (candidateError) { failures.push(`${candidate.url}: ${candidateError instanceof Error ? candidateError.message : String(candidateError)}`); }
      }
      if (!uploaded) throw new Error(failures.join(" | ") || "official website exposed no logo candidates");
    } catch (organizationError) {
      log.reason = organizationError instanceof Error ? organizationError.message : String(organizationError);
      console.warn("organization logo fallback", log);
    }
    results.push(log);
  }
  return Response.json({ processed: results.length, saved: results.filter(r => r.status === "saved").length, failed: results.filter(r => r.status === "fallback").length, results });
});
