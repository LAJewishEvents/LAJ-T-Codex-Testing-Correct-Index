#!/usr/bin/env node
// Invokes the deployed Edge Function in repeatable batches. Keep the service-role
// key server-side; this script only needs the separately configured function secret.
const url = process.env.SUPABASE_URL;
const secret = process.env.ORGANIZATION_LOGO_BACKFILL_SECRET;
if (!url || !secret) {
  console.error("Set SUPABASE_URL and ORGANIZATION_LOGO_BACKFILL_SECRET before running the backfill.");
  process.exit(1);
}
const organizationFlag = process.argv.find(argument => argument.startsWith("--organization="));
const organization = organizationFlag ? organizationFlag.slice("--organization=".length).trim() : undefined;
let response;
try {
  response = await fetch(`${url}/functions/v1/backfill-organization-logos`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-backfill-secret": secret },
    body: JSON.stringify({
      limit: organization ? 1 : Number(process.env.BACKFILL_LIMIT) || 500,
      force: process.argv.includes("--force"),
      ...(organization ? { organization } : {}),
    }),
  });
} catch (error) {
  console.error(`Unable to reach the production backfill function: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
}
const result = await response.json().catch(() => ({ error: `HTTP ${response.status}` }));
console.log(JSON.stringify(result, null, 2));
if (!response.ok || result.error) process.exit(1);
