-- Migration 002: messages + matches
-- messages: conversation history with vector embeddings for RAG
-- matches:  scored pairs from Stage 1+2, plus agent-to-agent summaries

-- Messages — one row per chat turn
CREATE TABLE messages (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role        text NOT NULL CHECK (role IN ('user', 'assistant')),
  content     text NOT NULL,
  -- Embedding of this message for pgvector RAG retrieval
  -- Same model as profile_embedding: Gemini Embedding 2, 3072 dims
  -- halfvec: 16-bit float, half the storage, supports hnsw index up to 16k dims
  embedding   halfvec(3072),
  session_id  text,                    -- groups messages from the same conversation
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- Index for fast user message retrieval (most common query pattern)
CREATE INDEX messages_user_id_idx ON messages (user_id, created_at DESC);

-- pgvector index for semantic search (cosine distance)
-- halfvec_cosine_ops: the operator class for halfvec cosine similarity
CREATE INDEX messages_embedding_idx ON messages
  USING hnsw (embedding halfvec_cosine_ops)
  WITH (m = 16, ef_construction = 64);

ALTER TABLE messages ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users read own messages"
  ON messages FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "users insert own messages"
  ON messages FOR INSERT
  WITH CHECK (auth.uid() = user_id);


-- Matches — one row per user pair that passed Stage 1+2
CREATE TABLE matches (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_a        uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  user_b        uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,

  -- Stage 2 output
  score         float NOT NULL DEFAULT 0.0,          -- 0.0–1.0 compatibility score
  commonalities text[] NOT NULL DEFAULT '{}',         -- top shared traits
  differences   text[] NOT NULL DEFAULT '{}',         -- key differences
  rationale     text NOT NULL DEFAULT '',             -- 2-3 sentence explanation

  -- Stage 3 output (agent-to-agent conversation)
  -- Separate summaries — neither user sees the other's private summary
  summary_a     text,    -- what user_a's agent learned (visible to user_a only)
  summary_b     text,    -- what user_b's agent learned (visible to user_b only)
  convo_transcript jsonb, -- full turn-by-turn transcript (service role only)

  -- State machine
  status        text NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending', 'shown', 'a2a_requested', 'a2a_running', 'a2a_done')),

  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),

  -- A pair should only appear once
  UNIQUE (user_a, user_b)
);

CREATE TRIGGER matches_updated_at
  BEFORE UPDATE ON matches
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE matches ENABLE ROW LEVEL SECURITY;

-- Each user can only see matches they are part of
CREATE POLICY "users read own matches"
  ON matches FOR SELECT
  USING (auth.uid() = user_a OR auth.uid() = user_b);

-- Index to quickly find all matches for a user
CREATE INDEX matches_user_a_idx ON matches (user_a);
CREATE INDEX matches_user_b_idx ON matches (user_b);
