const { json, twiml, parseBody, smsLine, selectEvents, loadEvents, eventTime, eventPlace } = require('./_shared');

const sessions = new Map();

async function handle(event) {
  if (event.httpMethod && event.httpMethod !== 'POST') return json(405, { ok:false, error:'Method not allowed' });
  try{
    const body = parseBody(event);
    const from = body.From || body.from || 'demo';
    const message = String(body.Body || body.body || '').trim();
    const previous = sessions.get(from) || [];

    if (/^[123]$/.test(message) && previous.length){
      const selected = previous[Number(message) - 1];
      if (selected){
        return twiml(`You're set for ${selected.title} — ${eventTime(selected)} — ${eventPlace(selected)}. Reply with a friend's phone number to invite them.`);
      }
    }

    const events = await loadEvents();
    const picks = selectEvents(events, message);
    sessions.set(from, picks);
    const prefix = picks.length && /tonight/i.test(message) && /westwood/i.test(message)
      ? 'Tonight near Westwood:'
      : 'Closest LAJT picks:';
    const response = picks.length
      ? `${prefix}\n${picks.map(smsLine).join('\n')}\nReply 1, 2, or 3 to choose.`
      : 'No LAJT events found yet. Check the app for the latest community listings.';
    return twiml(response);
  }catch(err){
    return twiml('Sorry, LAJT SMS is having trouble loading events right now. Please try again soon.');
  }
}

function fromVercelReq(req){
  const body = typeof req.body === 'string' ? req.body : new URLSearchParams(req.body || {}).toString();
  return { httpMethod:req.method, headers:req.headers || {}, body };
}

async function vercelHandler(req, res){
  const result = await handle(fromVercelReq(req));
  Object.entries(result.headers || {}).forEach(([key, value]) => res.setHeader(key, value));
  res.status(result.statusCode).send(result.body);
}

module.exports = vercelHandler;
module.exports.handler = handle;
module.exports._test = { selectEvents };
