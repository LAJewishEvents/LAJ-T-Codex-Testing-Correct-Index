const { json, parseBody, normalizePhone, eventTime, eventPlace, eventLink, sendSms } = require('./_shared');

exports.handler = async (event) => {
  if (event.httpMethod && event.httpMethod !== 'POST') return json(405, { ok:false, error:'Method not allowed' });
  try{
    const body = parseBody(event);
    const to = normalizePhone(body.phone || body.to);
    const selected = body.event || {};
    if (!to) return json(400, { ok:false, error:'Enter a valid US or E.164 phone number.' });
    if (!selected.title) return json(400, { ok:false, error:'Missing event details.' });
    const message = `LAJT reminder: You're interested in ${selected.title} — ${eventTime(selected)} — ${eventPlace(selected)}. Details: ${eventLink(selected)}`;
    const result = await sendSms(to, message);
    if (!result.configured) return json(503, { ok:false, configured:false, error:'SMS demo not configured. Add Twilio environment variables.' });
    return json(200, { ok:true, sid:result.sid });
  }catch(err){
    return json(500, { ok:false, error:err.message || 'SMS reminder failed' });
  }
};
