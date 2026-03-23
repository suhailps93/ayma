-- Migration 003: user_skills, user_tokens, rate_limits, llm_usage_log

-- User skills — prompt/tool/MCP skill files attached to a user's agent
CREATE TABLE user_skills (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name        text NOT NULL,
  skill_type  text NOT NULL CHECK (skill_type IN ('prompt', 'tool', 'mcp')),
  content     text NOT NULL,    -- the skill body (prompt text, tool code, MCP config)
  enabled     boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE user_skills ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users manage own skills"
  ON user_skills FOR ALL
  USING (auth.uid() = user_id);


-- User tokens — BYOT (Bring Your Own Token) for LLM providers
-- Keys are encrypted with Fernet (AES-256) before storage — never stored plaintext
CREATE TABLE user_tokens (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  provider     text NOT NULL CHECK (provider IN ('openai', 'anthropic', 'gemini', 'other')),
  -- encrypted_key: Fernet-encrypted API key — only decryptable server-side
  encrypted_key text NOT NULL,
  label        text,            -- user-friendly label e.g. "my OpenAI key"
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, provider)
);

ALTER TABLE user_tokens ENABLE ROW LEVEL SECURITY;

-- User can see that a key exists (for UI display) but NOT the encrypted value
CREATE POLICY "users read own token metadata"
  ON user_tokens FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "users insert own tokens"
  ON user_tokens FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "users delete own tokens"
  ON user_tokens FOR DELETE
  USING (auth.uid() = user_id);


-- Rate limits — per-user daily counters, reset nightly by a Cloud Tasks job
CREATE TABLE rate_limits (
  user_id           uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  chat_turns        int NOT NULL DEFAULT 0,
  match_stage2_runs int NOT NULL DEFAULT 0,
  agent_convos      int NOT NULL DEFAULT 0,
  voice_minutes     int NOT NULL DEFAULT 0,
  reset_at          timestamptz NOT NULL DEFAULT (now() + interval '1 day')
);

ALTER TABLE rate_limits ENABLE ROW LEVEL SECURITY;

-- Users can read their own limits (so the UI can show "X turns remaining")
CREATE POLICY "users read own rate limits"
  ON rate_limits FOR SELECT
  USING (auth.uid() = user_id);

-- Only service role can update counters (no user policy for UPDATE)


-- LLM usage log — observability + cost tracking per task
CREATE TABLE llm_usage_log (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  task          text NOT NULL,   -- 'chat', 'match_score', 'memory_extract', 'profile_update', etc.
  model         text NOT NULL,
  input_tokens  int NOT NULL DEFAULT 0,
  output_tokens int NOT NULL DEFAULT 0,
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- No RLS on usage log — service role writes only, users never query this directly
-- Frontend gets usage summary via a dedicated API endpoint if needed
