-- Migration 009: onboarding_complete flag on user_profiles
-- Tracks whether the user has completed the pre-boarding flow.
-- Set to true after the user submits the onboarding form.

ALTER TABLE user_profiles
  ADD COLUMN IF NOT EXISTS onboarding_complete boolean NOT NULL DEFAULT false;
