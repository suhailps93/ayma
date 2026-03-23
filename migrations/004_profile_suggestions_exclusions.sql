-- Migration 004: profile_suggestions + profile_exclusions

-- Profile suggestions — AI-written drafts waiting for user approval
-- Only used when profile_public_locked = true (user has taken manual control)
CREATE TABLE profile_suggestions (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  -- Which tier this suggestion is for (only 'public' for now — private is always auto-applied)
  tier        text NOT NULL CHECK (tier IN ('public')),
  draft       text NOT NULL,
  status      text NOT NULL DEFAULT 'pending'
              CHECK (status IN ('pending', 'accepted', 'dismissed')),
  created_at  timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE profile_suggestions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users manage own suggestions"
  ON profile_suggestions FOR ALL
  USING (auth.uid() = user_id);

-- Index: quickly find pending suggestions for a user
CREATE INDEX profile_suggestions_pending_idx
  ON profile_suggestions (user_id, status)
  WHERE status = 'pending';


-- Profile exclusions — topics the user has asked to keep off their public profile
-- Set via chat ("don't include my job in my profile") — detected in-graph
CREATE TABLE profile_exclusions (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  -- topic: what to exclude, e.g. "job", "religion", "relationship status"
  topic       text NOT NULL,
  -- tier: only 'public' is supported for now
  tier        text NOT NULL DEFAULT 'public' CHECK (tier IN ('public')),
  created_at  timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE profile_exclusions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users manage own exclusions"
  ON profile_exclusions FOR ALL
  USING (auth.uid() = user_id);
