-- Enable pgvector extension
CREATE EXTENSION IF NOT EXISTS "vector";

-- 1. Users Table
CREATE TABLE IF NOT EXISTS users (
    id VARCHAR(100) PRIMARY KEY, -- Supports Firebase Auth UIDs
    display_name VARCHAR(100),
    profile_public TEXT DEFAULT '',
    profile_private TEXT DEFAULT '',
    profile_ai_observations TEXT DEFAULT '',
    agent_name VARCHAR(100) DEFAULT 'Ayma',
    voice_preference VARCHAR(50) DEFAULT 'Charon',
    matching_prefs JSONB DEFAULT '{}'::jsonb,
    age INT,
    gender VARCHAR(50),
    location_region VARCHAR(100),
    location_coords JSONB DEFAULT '{}'::jsonb,
    onboarding_complete BOOLEAN DEFAULT FALSE,
    matching_paused BOOLEAN DEFAULT FALSE,
    preboarding_seen BOOLEAN DEFAULT FALSE,
    photo_order JSONB DEFAULT '[]'::jsonb,
    voice_settings JSONB DEFAULT '{}'::jsonb,
    
    -- Specific Flutter user profile properties
    profile_public_locked BOOLEAN DEFAULT FALSE,
    community_profile VARCHAR(100) DEFAULT 'dating_standard',
    profile_public_user_edited BOOLEAN DEFAULT FALSE,
    profile_public_pending TEXT DEFAULT '',
    
    -- Karpathy-style Memory Wiki (Flat Columns)
    wiki_about_me TEXT DEFAULT '',
    wiki_context TEXT DEFAULT '',
    wiki_preferences TEXT DEFAULT '',
    wiki_matching TEXT DEFAULT '',
    wiki_profile_structured TEXT DEFAULT '',
    
    -- Answer storage mimics (JSONB maps of field_id -> value/metadata)
    profile_answers JSONB DEFAULT '{}'::jsonb,
    profile_answers_public JSONB DEFAULT '{}'::jsonb,
    profile_answers_private JSONB DEFAULT '{}'::jsonb,
    profile_answers_sensitive JSONB DEFAULT '{}'::jsonb,
    profile_field_visibility JSONB DEFAULT '{}'::jsonb,
    
    -- Verbatim statement logs
    raw_user_statements JSONB DEFAULT '[]'::jsonb,
    
    -- Embeddings for matching similarity
    matching_embedding vector(1536), -- gemini-embedding-2 with output_dimensionality=1536

    -- FCM push token (updated by /device-token on app launch)
    fcm_token VARCHAR(512),

    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Index user data for quick matching lookups
CREATE INDEX IF NOT EXISTS idx_users_matching_filters ON users(gender, age, onboarding_complete, matching_paused);

-- 2. User Skills Table
CREATE TABLE IF NOT EXISTS user_skills (
    user_id VARCHAR(100) REFERENCES users(id) ON DELETE CASCADE,
    skill_id VARCHAR(100),
    name VARCHAR(200),
    content TEXT,
    enabled BOOLEAN DEFAULT TRUE,
    PRIMARY KEY (user_id, skill_id)
);

-- 3. User Questions Table (checklist system)
CREATE TABLE IF NOT EXISTS user_questions (
    user_id VARCHAR(100) REFERENCES users(id) ON DELETE CASCADE,
    question_id VARCHAR(100),
    key VARCHAR(100),
    text TEXT,
    category VARCHAR(100),
    sort_order INT DEFAULT 99,
    answered BOOLEAN DEFAULT FALSE,
    answered_at TIMESTAMP WITH TIME ZONE,
    is_followup BOOLEAN DEFAULT FALSE,
    PRIMARY KEY (user_id, question_id)
);

CREATE INDEX IF NOT EXISTS idx_user_questions_pending ON user_questions(user_id, answered, is_followup);

-- 4. Matches Table
CREATE TABLE IF NOT EXISTS matches (
    id SERIAL PRIMARY KEY,
    user_a VARCHAR(100) REFERENCES users(id) ON DELETE CASCADE,
    user_b VARCHAR(100) REFERENCES users(id) ON DELETE CASCADE,
    score NUMERIC(4,3),
    rationale TEXT,
    summary_a TEXT,
    summary_b TEXT,
    synergy_score INT,
    synergy_summary TEXT,
    status VARCHAR(20) DEFAULT 'pending', -- pending, accepted, rejected
    show_simulation_transcript BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    CONSTRAINT unique_match_pair UNIQUE (user_a, user_b)
);

CREATE INDEX IF NOT EXISTS idx_matches_lookup ON matches(user_a, user_b);

-- 5. Match Agent-to-Agent Simulations Table
CREATE TABLE IF NOT EXISTS match_simulations (
    id SERIAL PRIMARY KEY,
    match_id INT REFERENCES matches(id) ON DELETE CASCADE,
    sender_uid VARCHAR(100) REFERENCES users(id) ON DELETE CASCADE,
    turn_index INT NOT NULL,
    message_text TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 6. User Memories Table (Audit Log)
CREATE TABLE IF NOT EXISTS user_memories (
    id SERIAL PRIMARY KEY,
    user_id VARCHAR(100) REFERENCES users(id) ON DELETE CASCADE,
    text TEXT NOT NULL,
    session_id VARCHAR(100),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 7. User Media Table
CREATE TABLE IF NOT EXISTS user_media (
    id SERIAL PRIMARY KEY,
    user_id VARCHAR(100) REFERENCES users(id) ON DELETE CASCADE,
    photo_url TEXT NOT NULL,
    caption TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 8. Notifications Table
CREATE TABLE IF NOT EXISTS notifications (
    id SERIAL PRIMARY KEY,
    user_id VARCHAR(100) REFERENCES users(id) ON DELETE CASCADE,
    type VARCHAR(50),
    title VARCHAR(200),
    body TEXT,
    meta JSONB DEFAULT '{}'::jsonb,
    read BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_notifications_unread ON notifications(user_id, read);

-- 9. Direct Messages Table
CREATE TABLE IF NOT EXISTS messages (
    id SERIAL PRIMARY KEY,
    from_user_id VARCHAR(100) REFERENCES users(id) ON DELETE CASCADE,
    to_user_id VARCHAR(100) REFERENCES users(id) ON DELETE CASCADE,
    text TEXT NOT NULL,
    read BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_messages_chat ON messages(from_user_id, to_user_id);
