-- user_media: multimodal embeddings for user photos
-- Enables cross-modal matching: text query → finds photos in same embedding space
-- Embedding model: gemini-embedding-2-preview (768 dims, photo + caption combined)

create extension if not exists vector;

create table if not exists user_media (
    id          uuid primary key default gen_random_uuid(),
    user_id     uuid not null references auth.users(id) on delete cascade,
    photo_url   text not null,
    caption     text not null default '',
    embedding   vector(768),
    uploaded_at timestamptz not null default now()
);

create index on user_media using ivfflat (embedding vector_cosine_ops) with (lists = 100);
create index on user_media (user_id);

-- Cross-modal match: given a text query embedding, find users whose photos match
-- Usage: select * from match_user_photos(query_vec, current_user_id, 20);
create or replace function match_user_photos(
    query_embedding  vector(768),
    exclude_user_id  uuid,
    match_count      int default 20
)
returns table (
    user_id     uuid,
    photo_url   text,
    caption     text,
    similarity  float
)
language sql stable as $$
    select
        user_id,
        photo_url,
        caption,
        1 - (embedding <=> query_embedding) as similarity
    from user_media
    where user_id != exclude_user_id
      and embedding is not null
    order by embedding <=> query_embedding
    limit match_count;
$$;
