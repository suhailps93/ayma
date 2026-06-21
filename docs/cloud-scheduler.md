# Cloud Scheduler — Ayma Matching Cron

## One-time setup

Run this once to create the daily matching job. Replace `BACKEND_URL` with your
Cloud Run service URL and `YOUR_CRON_SECRET` with a strong random string.

```bash
# Set these first
BACKEND_URL="https://ayma-bootstrap-XXXX-uc.a.run.app"
CRON_SECRET="$(openssl rand -hex 32)"

# Create the scheduler job
gcloud scheduler jobs create http ayma-run-matching \
  --location=us-central1 \
  --schedule="0 2 * * *" \
  --uri="${BACKEND_URL}/run-matching-cron" \
  --http-method=POST \
  --headers="X-Cron-Secret=${CRON_SECRET},Content-Type=application/json" \
  --message-body='{}' \
  --time-zone="UTC" \
  --description="Run Ayma matching engine for all active users"

# Store the secret in Cloud Run
gcloud run services update ayma-bootstrap \
  --region=us-central1 \
  --update-env-vars="CRON_SECRET=${CRON_SECRET}"

echo "CRON_SECRET=${CRON_SECRET}"  # save this somewhere safe
```

## Manual trigger (for testing)

```bash
curl -X POST "${BACKEND_URL}/run-matching-cron" \
  -H "X-Cron-Secret: ${CRON_SECRET}"
```

## Job details

| Field | Value |
|-------|-------|
| Endpoint | `POST /run-matching-cron` |
| Auth | `X-Cron-Secret` header (no Firebase JWT needed) |
| Schedule | Daily at 02:00 UTC |
| What it does | Runs heuristic filter + Gemini scoring for every active user |
| FCM | Sends push notification to each newly matched user |
