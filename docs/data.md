# Data Layer

> **Status:** All tables ✅ | Auth trigger ✅ | Safe view ✅ | RLS ✅
>
> [← Back to Architecture](ARCHITECTURE.md)

---

## Table Relationships

```mermaid
erDiagram
    auth_users {
        uuid id PK
        text email
    }

    user_profiles {
        uuid id PK
        text display_name
        text profile_public
        text profile_private
        text profile_ai_observations
        halfvec profile_embedding "3072 dims"
        boolean profile_public_locked
        text agent_name
        text voice_preference
        jsonb matching_prefs
        int age
        text gender
        text religion
        text location_region
    }

    messages {
        uuid id PK
        uuid user_id FK
        text role
        text content
        halfvec embedding "3072 dims"
        text session_id
        timestamptz created_at
    }

    matches {
        uuid id PK
        uuid user_a FK
        uuid user_b FK
        float score
        array commonalities
        array differences
        text rationale
        text summary_a
        text summary_b
        jsonb convo_transcript
        text status
    }

    profile_suggestions {
        uuid id PK
        uuid user_id FK
        text tier
        text draft
        text status
    }

    profile_exclusions {
        uuid id PK
        uuid user_id FK
        text topic
        text tier
    }

    user_skills {
        uuid id PK
        uuid user_id FK
        text name
        text skill_type
        text content
        boolean enabled
    }

    user_tokens {
        uuid id PK
        uuid user_id FK
        text provider
        text encrypted_key
        text label
    }

    rate_limits {
        uuid user_id PK
        int chat_turns
        int match_stage2_runs
        int agent_convos
        int voice_minutes
        timestamptz reset_at
    }

    llm_usage_log {
        uuid id PK
        uuid user_id FK
        text task
        text model
        int input_tokens
        int output_tokens
    }

    auth_users ||--|| user_profiles : "trigger on signup"
    auth_users ||--o{ messages : ""
    auth_users ||--o{ profile_suggestions : ""
    auth_users ||--o{ profile_exclusions : ""
    auth_users ||--o{ user_skills : ""
    auth_users ||--o{ user_tokens : ""
    auth_users ||--|| rate_limits : ""
    auth_users ||--o{ llm_usage_log : ""
    auth_users ||--o{ matches : "user_a or user_b"
```

---

## user_profile_safe View

The client **never** reads from `user_profiles` directly. It reads from this view,
which structurally excludes `profile_ai_observations`.

```sql
CREATE VIEW user_profile_safe AS
  SELECT
    id, display_name, created_at, updated_at,
    profile_public, profile_private,
    -- profile_ai_observations intentionally excluded
    profile_public_locked, agent_name, voice_preference,
    matching_prefs, age, gender, religion, location_region
  FROM user_profiles;
```

---

## Who reads/writes what

| Column | Client can read | Client can write | Backend writes |
|--------|----------------|-----------------|----------------|
| `profile_public` | ✅ (via view) | ✅ (if locked=true) | ✅ (if locked=false) |
| `profile_private` | ✅ (via view) | ❌ | ✅ always |
| `profile_ai_observations` | ❌ never | ❌ | ✅ always |
| `profile_embedding` | ❌ | ❌ | ✅ after profile update |
| `profile_public_locked` | ✅ | ✅ | ✅ |

---

## Vector Storage

Both `profile_embedding` and `messages.embedding` use `halfvec(3072)`:
- **Model:** Gemini Embedding 2 (`gemini-embedding-2-preview`)
- **Dims:** 3072
- **Type:** `halfvec` (16-bit float) — half storage vs `vector`, supports hnsw index above 2000 dims
- **Index:** `hnsw` with `halfvec_cosine_ops`
- **Distance metric:** cosine similarity (`<=>` operator)

---

## RLS Policy Summary

| Table | Authenticated user can |
|-------|----------------------|
| `user_profiles` | Read/update own row only |
| `messages` | Read/insert own rows only |
| `matches` | Read rows where they are user_a or user_b |
| `profile_suggestions` | Full CRUD on own rows |
| `profile_exclusions` | Full CRUD on own rows |
| `user_skills` | Full CRUD on own rows |
| `user_tokens` | Read metadata + insert + delete own rows (no update) |
| `rate_limits` | Read own row only (counter updates: service role only) |
| `llm_usage_log` | No access (service role only) |

---

## Auth Trigger

When a user signs up, Supabase fires `on_auth_user_created`, which runs
`public.handle_new_user()` and inserts a row into `user_profiles` automatically.

```sql
-- Critical: SET search_path = public
-- Without this, the trigger can't find user_profiles (search_path defaults to auth)
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
```
