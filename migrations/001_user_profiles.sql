-- Migration 001: user_profiles
-- The core table. Three-tier profile system + matching preferences.
-- All profile text is written by the AI, never directly by the user.

-- Enable pgvector (idempotent — safe to run even if already enabled)
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE user_profiles (
  -- Identity
  id               uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name     text NOT NULL DEFAULT '',
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),

  -- Three-tier profile (all written by AI)
  -- Tier 1: Public — what anyone can see, used in agent-to-agent convos
  profile_public           text NOT NULL DEFAULT '',
  -- Tier 2: Private — only the user sees this, shapes how agent talks to them
  profile_private          text NOT NULL DEFAULT '',
  -- Tier 3: AI observations — NEVER exposed to client, matching + tone use only
  profile_ai_observations  text NOT NULL DEFAULT '',

  -- Embedding of the public profile for Stage 1 pgvector similarity ranking
  -- Using Gemini Embedding 2 (gemini-embedding-2-preview) — 3072 dims
  -- halfvec: 16-bit float, half the storage, supports hnsw index up to 16k dims
  profile_embedding        halfvec(3072),

  -- Public profile lock state
  -- false (default) = AI auto-rewrites after every session
  -- true            = AI only writes suggestions, user must accept
  profile_public_locked    boolean NOT NULL DEFAULT false,

  -- Agent personality (display name shown in chat, voice preference)
  agent_name       text NOT NULL DEFAULT 'Ayma',
  voice_preference text NOT NULL DEFAULT 'Charon',

  -- Structured matching preferences (what this user is looking for)
  -- Example: {"min_age": 25, "max_age": 40, "genders": ["female"], "religions": ["any"]}
  matching_prefs   jsonb NOT NULL DEFAULT '{}',

  -- User's own demographic info (used as filter targets by others' Stage 1)
  age              int,
  gender           text,
  religion         text,
  location_region  text
);

-- Auto-update updated_at on any row change
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER user_profiles_updated_at
  BEFORE UPDATE ON user_profiles
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- RLS
ALTER TABLE user_profiles ENABLE ROW LEVEL SECURITY;

-- Users can read their own row (but only through the safe view — see migration 006)
CREATE POLICY "users read own profile"
  ON user_profiles FOR SELECT
  USING (auth.uid() = id);

-- Users can update their own row (only non-sensitive fields — enforced at app layer)
CREATE POLICY "users update own profile"
  ON user_profiles FOR UPDATE
  USING (auth.uid() = id);

-- Service role can do everything (used by backend for AI writes)
-- Service role bypasses RLS by default in Supabase — no policy needed.

-- Profile is created automatically when a user signs up (via Supabase Auth trigger)
-- IMPORTANT: SET search_path = public is required.
-- Without it, when this trigger fires in the context of auth.users,
-- the search_path defaults to 'auth' and public.user_profiles is not found.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  INSERT INTO public.user_profiles (id, display_name)
  VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'full_name', ''));
  RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();
