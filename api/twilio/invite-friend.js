const { json, parseBody, normalizePhone, eventTime, eventPlace, eventLink, sendSms } = require('./_shared');

async function handle(event) {
  if (event.httpMethod && event.httpMethod !== 'POST') return json(405, { ok:false, error:'Method not allowed' });
  try{
    const body = parseBody(event);
    const to = normalizePhone(body.friendPhone || body.to);
    const selected = body.event || {};
    if (!to) return json(400, { ok:false, error:'Enter a valid friend phone number.' });
    if (!selected.title) return json(400, { ok:false, error:'Missing event details.' });
    const inviter = String(body.inviterName || 'A friend').trim() || 'A friend';
    const message = `${inviter} invited you via LA Jewish Tonight: ${selected.title} — ${eventTime(selected)} — ${eventPlace(selected)}. ${eventLink(selected)}`;
    const result = await sendSms(to, message);
    if (!result.configured) return json(503, { ok:false, configured:false, error:'SMS demo not configured yet.' });
    return json(200, { ok:true, sid:result.sid });
  }catch(err){
    return json(500, { ok:false, error:err.message || 'SMS invite failed' });
  }
}

function fromVercelReq(req){
  return { httpMethod:req.method, headers:req.headers || {}, body: typeof req.body === 'string' ? req.body : JSON.stringify(req.body || {}) };
}

async function vercelHandler(req, res){
  const result = await handle(fromVercelReq(req));
  Object.entries(result.headers || {}).forEach(([key, value]) => res.setHeader(key, value));
  res.status(result.statusCode).send(result.body);
}

module.exports = vercelHandler;
module.exports.handler = handle;
