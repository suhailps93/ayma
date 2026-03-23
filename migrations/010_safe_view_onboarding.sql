-- Migration 010: Add onboarding_complete to user_profile_safe view
-- Migration 009 added the column to user_profiles but did not update the view.
-- The client reads all profile data exclusively through this view.

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
    onboarding_complete
  FROM user_profiles;
