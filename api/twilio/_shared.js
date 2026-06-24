const DEFAULT_SUPABASE_URL = 'https://sigivdodtiewgscokdmk.supabase.co';
const DEFAULT_SUPABASE_KEY = 'sb_publishable_gK-ytjOr7gd9mygiS2YHQA_qLhtCaCV';

function json(statusCode, payload){
  return { statusCode, headers: { 'content-type': 'application/json' }, body: JSON.stringify(payload) };
}

function twiml(message){
  const safe = escapeXml(String(message || ''));
  return { statusCode: 200, headers: { 'content-type': 'text/xml' }, body: `<?xml version="1.0" encoding="UTF-8"?><Response><Message>${safe}</Message></Response>` };
}

function escapeXml(value){
  return String(value || '').replace(/[<>&'"]/g, ch => ({'<':'&lt;','>':'&gt;','&':'&amp;',"'":'&apos;','"':'&quot;'}[ch]));
}

function parseBody(event){
  const raw = event?.body || '';
  if (!raw) return {};
  const contentType = String(event?.headers?.['content-type'] || event?.headers?.['Content-Type'] || '').toLowerCase();
  if (contentType.includes('application/json')) return JSON.parse(raw || '{}');
  const params = new URLSearchParams(raw);
  return Object.fromEntries(params.entries());
}

function normalizePhone(phone){
  const cleaned = String(phone || '').trim().replace(/[\s().-]/g, '');
  if (/^\+[1-9]\d{7,14}$/.test(cleaned)) return cleaned;
  if (/^1\d{10}$/.test(cleaned)) return `+${cleaned}`;
  if (/^\d{10}$/.test(cleaned)) return `+1${cleaned}`;
  return '';
}

function eventTime(event){
  if (!event?.start_time) return 'Time TBA';
  const date = new Date(event.start_time);
  if (Number.isNaN(date.getTime())) return 'Time TBA';
  return date.toLocaleString('en-US', { weekday:'short', month:'short', day:'numeric', hour:'numeric', minute:'2-digit', timeZone:'America/Los_Angeles' });
}

function eventPlace(event){
  return event?.region || event?.location || 'Los Angeles';
}

function appUrl(){
  return String(process.env.PUBLIC_APP_URL || 'https://lajandrew.github.io/LiveFeed/').replace(/\/$/, '');
}

function eventLink(event){
  const base = appUrl();
  return event?.public_event_url || event?.event_url || event?.google_event_url || event?.rsvp_link || `${base}/?event=${encodeURIComponent(event?.id || '')}`;
}

function smsLine(event, index){
  return `${index}. ${event?.title || 'Event'} — ${eventTime(event)} — ${eventPlace(event)}`;
}

function isTonight(event, now = new Date()){
  const d = new Date(event?.start_time || '');
  if (Number.isNaN(d.getTime())) return false;
  const la = new Intl.DateTimeFormat('en-CA', { timeZone:'America/Los_Angeles', year:'numeric', month:'2-digit', day:'2-digit' });
  return la.format(d) === la.format(now);
}

function matchesWestwood(event){
  const haystack = [event?.title, event?.description, event?.location, event?.region, event?.organization].join(' ').toLowerCase();
  return /(westwood|ucla|westside|west la|brentwood|beverly hills|century city|santa monica)/i.test(haystack);
}

function selectEvents(events, query){
  const rows = (events || []).filter(Boolean).sort((a,b) => new Date(a.start_time || 0) - new Date(b.start_time || 0));
  const wantsTonight = /tonight/i.test(query || '');
  const wantsWestwood = /westwood|ucla|westside/i.test(query || '');
  let matches = rows.filter(e => (!wantsTonight || isTonight(e)) && (!wantsWestwood || matchesWestwood(e)));
  if (!matches.length) matches = rows.filter(e => new Date(e.start_time || 0).getTime() >= Date.now());
  if (!matches.length) matches = rows;
  return matches.slice(0, 3);
}

async function loadEvents(){
  const supabaseUrl = process.env.SUPABASE_URL || DEFAULT_SUPABASE_URL;
  const supabaseKey = process.env.SUPABASE_ANON_KEY || process.env.SUPABASE_KEY || DEFAULT_SUPABASE_KEY;
  const fields = 'id,title,description,start_time,end_time,location,rsvp_link,category,region,organization,public_event_url,event_url,google_event_url';
  const nowIso = new Date(Date.now() - 6 * 60 * 60 * 1000).toISOString();
  const url = `${supabaseUrl}/rest/v1/events?select=${encodeURIComponent(fields)}&end_time=gte.${encodeURIComponent(nowIso)}&order=start_time.asc&limit=80`;
  const resp = await fetch(url, { headers: { apikey: supabaseKey, authorization: `Bearer ${supabaseKey}`, accept:'application/json' } });
  if (!resp.ok) throw new Error(`Supabase events failed: ${resp.status}`);
  const data = await resp.json();
  return Array.isArray(data) ? data : [];
}

function twilioConfigured(){
  return !!(process.env.TWILIO_ACCOUNT_SID && process.env.TWILIO_AUTH_TOKEN && process.env.TWILIO_FROM_NUMBER);
}

async function sendSms(to, body){
  if (!twilioConfigured()) return { configured:false, sid:null };
  const sid = process.env.TWILIO_ACCOUNT_SID;
  const token = process.env.TWILIO_AUTH_TOKEN;
  const resp = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(sid)}/Messages.json`, {
    method:'POST',
    headers: { authorization: `Basic ${Buffer.from(`${sid}:${token}`).toString('base64')}`, 'content-type':'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ To: to, From: process.env.TWILIO_FROM_NUMBER, Body: body })
  });
  const data = await resp.json().catch(() => ({}));
  if (!resp.ok) throw new Error(data.message || `Twilio failed: ${resp.status}`);
  return { configured:true, sid:data.sid };
}

module.exports = { json, twiml, parseBody, normalizePhone, eventTime, eventPlace, eventLink, smsLine, selectEvents, loadEvents, sendSms, twilioConfigured };
