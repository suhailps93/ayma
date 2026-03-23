# Ayma — Build Plan

> **Rule:** Do ONE step at a time. Do not move to the next step until the current one works
> and you understand why it works — not just that it works.
>
> **Client Boundary:** Keep the client as thin as possible. The web app and Flutter app should
> only handle presentation, device capabilities (mic/camera/playback), and authenticated API /
> WebSocket calls. Auth, session lifecycle, profile writes, matching logic, location lookup,
> and all business logic belong in the backend.
>
> **Goal:** Build a production-grade personalized AI matchmaking platform, and understand
> every layer of the architecture as we go.

---

## What We Are Building (Plain English)

Ayma is a matchmaking app where:
- Each user talks to their own personal AI agent (text or voice)
- The agent learns who the user is over time and writes their profile automatically
- The system quietly matches users in the background using a two-stage process
- When a match looks good, users can let their two AI agents have a conversation first
- Profiles have three layers: what others see, what only the user sees, and what only the AI sees

---

## Architecture at a Glance

```
User (browser / CLI)
      |
      | WebSocket (text) or ADK Streaming (voice)
      v
Vertex AI Agent Engine  <-- our backend lives here
      |
      |-- LangGraph Agent  <-- the AI brain per user
      |-- Cloud Tasks      <-- background jobs (no Celery, no Redis)
      |
      v
Supabase  <-- all data (PostgreSQL + pgvector + Auth)
Mem0      <-- structured facts about each user
Graphiti/Kuzu  <-- relationship graph for matching
```

---

## The Checklist

Each step has:
- What to build
- What you should understand after finishing it
- Alternatives we considered and why we chose what we chose

---

### PHASE 0 — Scaffold ✅

- [x] **Step 0.1** — Install prerequisites and understand what `agent-starter-pack` gives us
- [x] **Step 0.2** — Scaffold the repo using `adk_live` template, rename everything to `ayma`
- [x] **Step 0.3** — Run the scaffold locally, understand the folder structure, what each file does

---

### PHASE 1 — Data Layer (Supabase) ✅

- [x] **Step 1.1** — Create Supabase project, enable pgvector, understand what RLS is and why we need it
- [x] **Step 1.2** — Write and run migration: `user_profiles` table with 3-tier profile columns
- [x] **Step 1.3** — Write and run migration: `messages`, `matches` tables + pgvector column
- [x] **Step 1.4** — Write and run migration: `user_skills`, `user_tokens`, `rate_limits`, `llm_usage_log`
- [x] **Step 1.5** — Write and run migration: `profile_suggestions`, `profile_exclusions`
- [x] **Step 1.6** — Create `user_profile_safe` VIEW (this is how we block `ai_observations` from ever reaching the client)
- [x] **Step 1.7** — Write all RLS policies, test them — understand what would break without them
- [ ] **Step 1.8** — Wire Supabase Auth into the backend (replace/wrap the scaffold's default auth)

---

### PHASE 2 — Personalized Agent (LangGraph)

- [x] **Step 2.1** — Understand LangGraph: nodes, edges, state, checkpointer — draw the graph on paper first
- [x] **Step 2.2** — Define `AgentState` (the data that flows through the graph)
- [x] **Step 2.3** — Build the `retrieve` node — fetches Mem0 facts + pgvector RAG in parallel
- [x] **Step 2.4** — Build the `personality` node — assembles the system prompt from profile tiers
- [x] **Step 2.5** — Build the `respond` node — calls Gemini Flash, streams response to client
- [x] **Step 2.6** — Build the `memorize` node — async post-turn: Mem0 write + pgvector embed
- [x] **Step 2.7** — Wire up the full graph: retrieve → personality → respond → memorize
- [x] **Step 2.8** — Add exclusion detection in the `respond` node ("don't mention my job")
- [x] **Step 2.9** — Add Cloud Tasks enqueue in `memorize` node for profile tier updates
- [x] **Step 2.10** — Build the `/internal/update-profile` Cloud Tasks handler (3-tier rewrite with Flash)
- [x] **Step 2.11** — Add BYOT key management (encrypt/store/retrieve, Fernet)

---

### PHASE 3 — Voice (ADK Streaming + Gemini Live)

- [x] **Step 3.1** — Understand the difference between text WebSocket and ADK Streaming voice channel
- [x] **Step 3.2** — Swap the scaffold's default system prompt for Ayma's personalized personality output
- [x] **Step 3.3** — Wire Mem0 context into the Gemini Live session instructions
- [x] **Step 3.4** — Inject the voice modifier (1–3 sentence rule, no markdown)
- [x] **Step 3.5** — Add voice preference setting (Charon / Puck / Kore) stored in `user_profiles`

---

### PHASE 4 — Profile UI (React)

- [x] **Step 4.1** — Profile page: display AI-written public profile (read-only by default)
- [ ] **Step 4.2** — Overwrite button → sets `profile_public_locked = true`, AI switches to suggestion mode
- [ ] **Step 4.3** — `ProfileSuggestions` component — accept / dismiss AI nudges
- [ ] **Step 4.4** — Settings → "What's hidden from your public profile" (view + delete exclusions)
- [ ] **Step 4.5** — "Let AI manage this again" → resets `profile_public_locked = false`

---

### PHASE 5 — Matching Engine

- [ ] **Step 5.1** — Understand the two-stage design: why Stage 1 costs $0 and Stage 2 uses Flash
- [ ] **Step 5.2** — Build Stage 1: dynamic SQL filter + pgvector soft-rank → top 50 candidates
- [ ] **Step 5.3** — Build Stage 2: Flash scoring loop (50 candidates → top 10, structured JSON output)
- [ ] **Step 5.4** — Wrap Stage 1 + Stage 2 in Cloud Tasks jobs (scheduled + event-triggered)
- [ ] **Step 5.5** — React: `Matches` page with `MatchCard` (score, rationale, trigger button)
- [ ] **Step 5.6** — React: `AgentConsentModal` — preview what will be shared before Stage 3

---

### PHASE 6 — Agent-to-Agent (Stage 3)

- [ ] **Step 6.1** — Study the `adk_a2a` starter template — understand the A2A protocol
- [ ] **Step 6.2** — Build the Stage 3 agent prompts (public profile only, no leakage)
- [ ] **Step 6.3** — Build the summarizer — writes `summary_a` + `summary_b` separately to `matches`
- [ ] **Step 6.4** — Supabase Realtime → push notification to React when agent convo completes
- [ ] **Step 6.5** — End-to-end test: two test users, trigger Stage 3, verify no private data in transcript

---

### PHASE 7 — Polish

- [ ] **Step 7.1** — Skill loader: load prompt/tool/MCP skills from `user_skills` table at session start
- [ ] **Step 7.2** — Rate limiting: Supabase counter table, checked at agent entry point
- [ ] **Step 7.3** — Cost guardrails: token budget per task, off-peak scheduling via Cloud Tasks `schedule_time`
- [ ] **Step 7.4** — CLI: thin Python + rich WebSocket wrapper, same backend endpoint
- [ ] **Step 7.5** — Observability: verify Google Cloud Trace is capturing per-turn spans

---

## Decisions and Alternatives (Reference)

| Decision | What we chose | Alternative considered | Why we chose ours |
|----------|--------------|----------------------|-------------------|
| Voice infra | ADK Streaming + Gemini Live | LiveKit + Deepgram + separate TTS | One service vs three; Google manages VAD, turn detection, interruption |
| Background jobs | Cloud Tasks | Celery + Redis | No always-on worker/broker; fits Agent Engine's HTTP model |
| Graph database | Graphiti + Kuzu (embedded) | Neo4j | Zero extra infra; migrate to Neo4j at scale if needed |
| Memory facts | Mem0 v1.0.6 | Agent Engine Memory Bank alone | Mem0 gives structured facts; Memory Bank gives long-term recall; they complement each other |
| LLM default | Gemini 2.5 Flash | GPT-4o, Claude | Flash is fastest + cheapest; Google-native with Agent Engine; Pro available as optional upgrade |
| Auth | Backend-managed Supabase Auth + JWT | Client-owned Supabase SDK, Firebase Auth, Auth0 | Keeps clients thin, centralizes auth/session policy, still uses Supabase as the identity provider |
| Rate limiting | Supabase counter table | Redis, Upstash | Already have Supabase; Redis dropped intentionally |
| Frontend deploy | Vercel | Cloud Run, Netlify | Free tier; zero config for React |
| BYOT encryption | Fernet (AES-256) | AWS KMS, manual AES | Simple, server-side only, no external key service needed at this scale |

---

## Costs at MVP Scale

| Service | Cost |
|---------|------|
| Vertex AI Agent Engine | $0 (Express Mode, 90 days) |
| Supabase | $0 (free tier) |
| Cloud Tasks | $0 (1M tasks/mo free) |
| Gemini Flash | ~$0–5/mo at low traffic |
| Vercel | $0 |
| Mem0 Cloud | $0 (500 ops/mo free) |
| **Total** | **~$0–5/mo** |

---

## Current Step

**-> Step 1.8 — Wire Supabase Auth into the backend**

Thin-client auth is the active architecture rule. Do not add new direct database or auth logic to the clients.
