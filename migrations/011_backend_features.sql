-- Migration 011: backend-complete features
-- Adds pause matching, notifications, and media_type support for user_media.

ALTER TABLE user_profiles
  ADD COLUMN IF NOT EXISTS matching_paused boolean NOT NULL DEFAULT false;

ALTER TABLE user_media
  ADD COLUMN IF NOT EXISTS media_type text NOT NULL DEFAULT 'image'
  CHECK (media_type IN ('image', 'video'));

CREATE TABLE IF NOT EXISTS notifications (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  type        text NOT NULL CHECK (type IN ('new_match', 'agent_update', 'profile_suggestion', 'system')),
  title       text NOT NULL,
  body        text NOT NULL,
  meta        jsonb NOT NULL DEFAULT '{}'::jsonb,
  read        boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS notifications_user_created_idx
  ON notifications (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS notifications_user_unread_idx
  ON notifications (user_id, read)
  WHERE read = false;

ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'notifications' AND policyname = 'users read own notifications'
  ) THEN
    CREATE POLICY "users read own notifications"
      ON notifications FOR SELECT
      USING (auth.uid() = user_id);
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'notifications' AND policyname = 'users update own notifications'
  ) THEN
    CREATE POLICY "users update own notifications"
      ON notifications FOR UPDATE
      USING (auth.uid() = user_id);
  END IF;
END $$;

CREATE OR REPLACE VIEW user_profile_safe AS
  SELECT
    id,
    display_name,
    created_at,
    updated_at,
    profile_public,
    profile_private,
    profile_public_locked,
    agent_name,
    voice_preference,
    matching_prefs,
    age,
    gender,
    religion,
    location_region,
    community_profile,
    onboarding_complete,
    matching_paused
  FROM user_profiles;
