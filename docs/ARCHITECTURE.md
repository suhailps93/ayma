# Ayma — Architecture Overview

> **Legend:**
> - ✅ Implemented
> - 🔄 In progress
> - ⬜ Not started
>
> Click any section heading to drill into the detail doc for that subsystem.

---

## High-Level System Map

```mermaid
flowchart TB
    subgraph CLIENT["CLIENT LAYER"]
        direction LR
        Web["React Web App 🔄"]
        CLI["Python CLI ⬜"]
    end

    subgraph BACKEND["VERTEX AI AGENT ENGINE ⬜"]
        direction TB
        WS["WebSocket /ws/chat ⬜"]
        Voice["ADK Streaming /stream/voice ⬜"]
        API["REST /api/* ⬜"]
        Internal["Internal /internal/* ⬜"]
    end

    subgraph AGENT["LANGGRAPH AGENT ✅"]
        direction LR
        Retrieve["retrieve ✅"]
        Personality["personality ✅"]
        Respond["respond ✅"]
        Memorize["memorize ✅"]
        Retrieve --> Personality --> Respond --> Memorize
    end

    subgraph MEMORY["MEMORY LAYER — see memory.md"]
        Mem0["Mem0 facts ⬜"]
        PGVector["pgvector RAG ✅"]
        Graphiti["Graphiti/Kuzu graph ⬜"]
    end

    subgraph JOBS["BACKGROUND JOBS — Cloud Tasks ⬜"]
        ProfileUpdate["Profile tier updater ⬜"]
        Stage1["Matching Stage 1 — SQL ⬜"]
        Stage2["Matching Stage 2 — Flash ⬜"]
        Stage3["Agent-to-Agent Stage 3 ⬜"]
        MemWrite["Memory writer ⬜"]
    end

    subgraph DATA["DATA LAYER — see data.md"]
        Supabase["Supabase PostgreSQL ✅"]
        Auth["Supabase Auth ✅"]
    end

    Web -->|WebSocket + ADK Streaming| WS
    Web -->|ADK Streaming| Voice
    CLI -->|WebSocket| WS
    WS --> AGENT
    Voice --> AGENT
    AGENT --> MEMORY
    AGENT --> DATA
    AGENT -->|enqueue post-turn tasks| JOBS
    JOBS --> DATA
    JOBS --> MEMORY
    API --> DATA
    Internal --> JOBS
```

---

## Request Flow — Text Chat

How a single user message travels through the system end-to-end.

```mermaid
sequenceDiagram
    actor User
    participant React as React App ⬜
    participant WS as WebSocket Handler ⬜
    participant Graph as LangGraph Agent ⬜
    participant Mem0 as Mem0 ⬜
    participant PG as pgvector ✅
    participant LLM as Gemini Flash ⬜
    participant Tasks as Cloud Tasks ⬜

    User->>React: types message
    React->>WS: {type: "chat", content: "..."}
    WS->>Graph: invoke(state)

    Note over Graph: retrieve node
    Graph->>Mem0: get_facts(user_id)
    Graph->>PG: similarity_search(message)

    Note over Graph: personality node
    Graph->>Graph: build system prompt from<br/>profile tiers + skills + memory

    Note over Graph: respond node
    Graph->>LLM: stream(messages)
    LLM-->>React: {type: "chunk", content: "..."}
    LLM-->>React: {type: "done"}

    Note over Graph: memorize node
    Graph->>Tasks: enqueue(memory_write)
    Graph->>Tasks: enqueue(profile_update)

    Tasks-->>Mem0: add(last_exchange)
    Tasks-->>PG: embed_and_store(message)
```

---

## Request Flow — Voice

```mermaid
sequenceDiagram
    actor User
    participant React as React App ⬜
    participant ADK as ADK Streaming ⬜
    participant GeminiLive as Gemini Live ⬜
    participant Graph as LangGraph Agent ⬜

    User->>React: holds mic button
    React->>ADK: audio stream chunks
    ADK->>GeminiLive: bidirectional audio stream
    Note over GeminiLive: VAD + STT + LLM + TTS<br/>all in one round trip
    GeminiLive-->>ADK: audio response chunks
    ADK-->>React: plays audio in real time
    Note over ADK,Graph: session instructions injected<br/>from personality node at start
```

---

## Three-Tier Profile State Machine

```mermaid
stateDiagram-v2
    [*] --> AI_Managed: user signs up

    AI_Managed: AI Managed\n(profile_public_locked = false)
    AI_Managed --> AI_Managed: AI rewrites after every session\nautomatically applied

    AI_Managed --> User_Controlled: user submits own text\nto public profile field

    User_Controlled: User Controlled\n(profile_public_locked = true)
    User_Controlled --> Suggestion_Pending: AI detects new info\nwrites to profile_suggestions

    Suggestion_Pending: Suggestion Pending
    Suggestion_Pending --> User_Controlled: user dismisses
    Suggestion_Pending --> User_Controlled: user accepts\nprofile updated

    User_Controlled --> AI_Managed: user clicks\n"Let AI manage this again"
```

---

## Match Lifecycle

```mermaid
stateDiagram-v2
    [*] --> pending: Stage 2 creates match row

    pending --> shown: match displayed to user

    shown --> a2a_requested: user clicks trigger +\nconsent modal confirmed

    a2a_requested --> a2a_running: Cloud Task starts\nagent-to-agent convo

    a2a_running --> a2a_done: conversation ends\nsummary_a + summary_b written

    a2a_done --> [*]
```

---

## Implementation Status by Component

| Component | Status | Phase | Detail |
|-----------|--------|-------|--------|
| Supabase schema (all tables) | ✅ | Phase 1 | [data.md](data.md) |
| RLS policies | ✅ | Phase 1 | [data.md](data.md) |
| pgvector + halfvec(3072) | ✅ | Phase 1 | [data.md](data.md) |
| Auth trigger (signup → profile) | ✅ | Phase 1 | [data.md](data.md) |
| System skills (tone_mirror, deep_recall) | ✅ | Phase 1 | [agent.md](agent.md) |
| Supabase Auth → backend | 🔄 | Phase 2 | [agent.md](agent.md) |
| LangGraph agent graph | ✅ | Phase 2 | [agent.md](agent.md) |
| Mem0 integration | ✅ | Phase 2 | [memory.md](memory.md) |
| Profile tier update pipeline | ✅ | Phase 2 | [agent.md](agent.md) |
| Exclusion detection | ✅ | Phase 2 | [agent.md](agent.md) |
| BYOT key management | ✅ | Phase 2 | [agent.md](agent.md) |
| Voice (Gemini Live) | ✅ | Phase 3 | [agent.md](agent.md) |
| Profile UI | 🔄 | Phase 4 | Auth + profile read done (4.1) |
| Matching Stage 1 (SQL) | ⬜ | Phase 5 | [matching.md](matching.md) |
| Matching Stage 2 (Flash) | ⬜ | Phase 5 | [matching.md](matching.md) |
| Agent-to-Agent Stage 3 | ⬜ | Phase 6 | [matching.md](matching.md) |
| Skill loader + user skills UI | ⬜ | Phase 7 | [agent.md](agent.md) |
| Rate limiting | ⬜ | Phase 7 | — |
| CLI | ⬜ | Phase 7 | — |
