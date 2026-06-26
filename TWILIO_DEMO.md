# Twilio SMS demo setup

The LAJT SMS reminder/invite demo uses small serverless functions under `api/twilio/`.
Configure these environment variables in the hosting provider before enabling the demo:

- `TWILIO_ACCOUNT_SID`
- `TWILIO_AUTH_TOKEN`
- `TWILIO_FROM_NUMBER`
- `PUBLIC_APP_URL`
- Optional: `SUPABASE_URL` and `SUPABASE_ANON_KEY` if the hosted API should override the current LAJT public Supabase project.
- Optional AI/API key: not required for the minimum viable demo flow; the inbound handler uses deterministic event matching.

Point the Twilio Messaging webhook to `POST /api/twilio/inbound`. Frontend card actions call `POST /api/twilio/send-reminder` and `POST /api/twilio/invite-friend`.
