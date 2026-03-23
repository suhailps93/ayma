-- Migration 006: match_messages RPC function
-- Called by the retrieve node to fetch semantically similar past messages.
-- Exposed via Supabase PostgREST as supabase.rpc("match_messages", {...})

CREATE OR REPLACE FUNCTION match_messages(
    query_embedding halfvec(3072),
    match_user_id   uuid,
    match_count     int DEFAULT 8
)
RETURNS TABLE (
    id         uuid,
    role       text,
    content    text,
    distance   float
)
LANGUAGE sql STABLE
AS $$
    SELECT
        id,
        role,
        content,
        (embedding <=> query_embedding)::float AS distance
    FROM messages
    WHERE user_id = match_user_id
      AND embedding IS NOT NULL
    ORDER BY embedding <=> query_embedding
    LIMIT match_count;
$$;

-- Allow authenticated users and service role to call this function
GRANT EXECUTE ON FUNCTION match_messages TO authenticated, service_role;
