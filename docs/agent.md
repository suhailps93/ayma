# Ayma Agent System

## Overview
Ayma uses a unified agent architecture for both text and voice, powered by a LangGraph state machine. It is designed to be proactive, inquisitive, and context-aware.

## The Agent Graph (LangGraph)

Every interaction follows this flow:

1. **Retrieve:**
   - Fetches atomic facts from **Mem0**.
   - Reads the **LLM Wiki** (`about_me`, `matching_profile`, `preferences`, `context`).
   - Retrieves the persistent **Question Checklist** and **Pending Questions** from Supabase.

2. **Personality:**
   - Assembles the final system prompt.
   - **Priority:** Persona > Question Checklist > Pending Questions > Wiki Context > Mem0 Facts.
   - Injects the `matchmaker.md` persona and any active skills.

3. **Respond:**
   - **Exclusion Check:** Detects if the user wants to hide information.
   - **LLM Generation:** Calls Gemini (Flash) to generate the response.
   - **Deferred Question Detection:** Identifies if the agent *should* have asked a question but held back to maintain flow.

4. **Memorize (Async):**
   - **Wiki Update:** Triggers parallel updates to all markdown wiki pages.
   - **Mem0 Sync:** Records new atomic facts.
   - **Checklist Sync:** Persists any new deferred questions to the database.

## Unified Persona
Both the Chat and Voice agents share the same core persona from `ayma/app/skills/system/matchmaker.md`.
- **Tone:** Warm, empathetic, and genuinely curious.
- **Objective:** Deep understanding of the user for high-quality matchmaking.
- **Rules:** Prioritize depth over surface-level facts; follow the user's lead while keeping the checklist in mind.

## Voice Specifics (Gemini Live)
In voice mode (`mode="voice"`), the agent appends a `VOICE_MODIFIER` to the prompt:
- Responses are limited to 1-3 sentences.
- Natural speech patterns (no markdown or lists).
- Emotional variety and mirroring of user energy.

## Persistent Checklist
Unlike standard bots that "forget" what they wanted to ask, Ayma uses the `questions_pending` column in Supabase. This turns a "mental note" into a durable task that persists across sessions and platforms. If Ayma thinks of a question in Chat, she might ask it later in a Voice call.
