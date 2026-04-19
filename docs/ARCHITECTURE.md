# Ayma System Architecture

## Overview
Ayma is a "Karpathy-style" LLM OS designed for personal matchmaking. It manages user memory through a hierarchical markdown knowledge base (The Wiki) and a persistent, database-backed information-gathering checklist.

## Core Components

### 1. The Agent Engine (ADK + LangGraph)
- **Chat Agent:** A LangGraph state machine that manages multi-turn text conversations, detects profile exclusions, and handles deferred questioning.
- **Voice Agent:** A high-performance Gemini Live (ADK) bridge for low-latency, emotionally expressive voice interaction.
- **Unified Persona:** Both agents share the `matchmaker.md` system prompt, focusing on genuine curiosity and depth.

### 2. Memory Hierarchy (The LLM OS)
- **Volatile RAM:** The current conversation turn.
- **L1 Cache (`context.md`):** Short-term context (recent life events, emotional state).
- **Swap Space (`about_me.md`, `preferences.md`):** Long-term persona and search desires.
- **Gold Record (`matching_profile.md`):** High-signal, structured specs for the matching engine.
- **Atomic Facts (Mem0):** Vector-indexed tiny details (e.g., "allergic to cats").
- **Persistent Checklist (`questions_pending`):** A Supabase JSONB column storing questions the agent intends to ask in future turns.

### 3. Asynchronous Synthesis
After every turn, the system runs a fire-and-forget synthesis pipeline:
- **Wiki Update:** 4 parallel LLM calls to "upsert" knowledge into the Markdown wiki files.
- **Mem0 Update:** Extraction of atomic facts from the conversation.
- **Checklist Update:** Syncing deferred questions to the database.

### 4. Matching Engine
- **Stage 1 (SQL):** Hard-filter by demographics (age, gender, location) in Supabase.
- **Stage 2 (LLM):** Scrutinize the top-K candidates by comparing their `matching_profile.md` files. This allows for nuanced compatibility scoring based on conflict style, social energy, and core values.

## Data Mapping
- **Structured (PostgreSQL):** Profile basics, auth, checklist, and feedback.
- **Semi-Structured (GCS/Local):** The LLM Wiki (Markdown Knowledge Base).
- **Unstructured (Mem0):** Vector-based atomic memories.
- **Binary (GCS/Local):** User-uploaded media (photos/videos).

## Deployment
- **Backend:** Python/FastAPI running as a `systemd` user service.
- **Exposure:** Cloudflare Tunnel provides stable HTTPS URLs for mobile clients.
- **Clients:** Flutter mobile app and web frontend.
