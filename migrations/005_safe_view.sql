-- Migration 005: user_profile_safe view
-- This view is the ONLY way the client ever reads profile data.
-- It deliberately excludes profile_ai_observations — that column
-- must never reach the frontend under any circumstances.
--
-- Why a view and not just RLS on the column?
-- PostgreSQL RLS works on rows, not columns. A view is the clean way
-- to hide specific columns at the database level.

CREATE VIEW user_profile_safe AS
  SELECT
    id,
    display_name,
    created_at,
    updated_at,
    profile_public,
    profile_private,
    -- profile_ai_observations is intentionally excluded
    profile_public_locked,
    agent_name,
    voice_preference,
    matching_prefs,
    age,
    gender,
    religion,
    location_region
  FROM user_profiles;

-- Grant authenticated users access to the view
GRANT SELECT ON user_profile_safe TO authenticated;

-- The underlying table is NOT directly accessible to authenticated role
-- (they can only read their own row via RLS, but we prefer they use the view)
-- Service role can still read/write the full table directly.
