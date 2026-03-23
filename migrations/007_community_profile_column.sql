-- Migration 007: community_profile column on user_profiles
-- Stores which question set / community profile this user is on.
-- The value maps to a YAML file in app/profiles/ on the server.
-- Default: dating_standard

ALTER TABLE user_profiles
  ADD COLUMN community_profile text NOT NULL DEFAULT 'dating_standard';

-- Also add to user_profile_safe view so the client can read it
-- (needed for future settings UI to show which profile a user is on)
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
    community_profile
  FROM user_profiles;
