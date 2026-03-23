-- Migration 008: app_feedback table
-- Stores universal app feedback (bugs, feature requests, UX issues)
-- Per-user preference feedback goes directly to user_skills instead.

CREATE TABLE IF NOT EXISTS app_feedback (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  feedback    text NOT NULL,
  category    text NOT NULL CHECK (category IN ('bug', 'feature_request', 'ux', 'other')),
  context     text,       -- what the user was doing / conversation snippet
  created_at  timestamptz NOT NULL DEFAULT now(),
  reviewed    boolean NOT NULL DEFAULT false
);

-- Users can insert their own feedback; nobody can read others'
ALTER TABLE app_feedback ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can insert feedback"
  ON app_feedback FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can read own feedback"
  ON app_feedback FOR SELECT
  USING (auth.uid() = user_id);
