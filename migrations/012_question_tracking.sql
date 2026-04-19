-- Migration 012: Question tracking
-- Stores pending questions that the agent wanted to ask but deferred.

ALTER TABLE user_profiles
  ADD COLUMN IF NOT EXISTS questions_pending jsonb NOT NULL DEFAULT '[]'::jsonb;

-- Update the safe view to include the new column
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
    matching_paused,
    questions_pending
  FROM user_profiles;
