# Ayma Memory System (LLM OS)

Ayma uses a hierarchical memory system based on the "LLM OS" architecture. This ensures that the agent has both a rich narrative understanding of the user and a high-speed factual index.

## 1. The Wiki Layer (Markdown Knowledge Base)
The Wiki is the "Hard Drive" of the system. It consists of specialized Markdown files that are loaded into the LLM's context window at the start of every session.

| File | Content | Update Frequency |
| :--- | :--- | :--- |
| **`about_me.md`** | 1st-person personality, voice, and communication style ("The Vibe"). | Per turn |
| **`matching_profile.md`** | 3rd-person factual specs (Career, Values, Social Energy, Conflict Style). | Per turn |
| **`preferences.md`** | Detailed attraction criteria and relationship goals. | Per turn |
| **`context.md`** | Current emotional state and short-term life events. | Per turn |
| **`media.md`** | Visual summaries and insights from uploaded photos/videos. | On upload |

### The "Upsert" Mechanism
Wiki pages are updated by `wiki_update.py`. Instead of just appending text, the LLM reads the current file and the new conversation, then performs an **intelligent upsert**:
- **Preserve:** Keep accurate existing info.
- **Correct:** Update stale info (e.g., "I just quit my job").
- **Prune:** Remove noise and redundant data.
- **ECC (Error Correction):** Strict no-hallucination prompts ensure the AI never invents details.

## 2. The Checklist Layer (Persistent Focus)
To ensure the agent actually gets to know the user, it maintains a two-part checklist:

1. **The Question Checklist:** A derived list based on the "Dating Standard" profile. It marks items (Name, Age, Location, etc.) as `[✓ known]` if they are in the database.
2. **Mental Notes (`questions_pending`):** A persistent JSONB column in Supabase. If the agent thinks of a question but the moment isn't right, it saves the question here for future turns.

## 3. The Atomic Layer (Mem0)
For tiny, granular facts that don't belong in a narrative (e.g., "Likes black coffee", "Allergic to peanuts"), Ayma uses **Mem0**.
- **Retrieval:** Top-K facts are pulled into the prompt via vector search.
- **Storage:** Managed in the Mem0 cloud (or local vector DB).

## 4. Context Window Management
By synthesizing conversation into the Wiki and atomic facts, we prevent the "infinite scroll" problem in context windows. 
- The **System Prompt** contains the high-signal "Gold Record" and "Persona."
- The **History** is truncated to the most recent turns.
- **RAG** (Retrieval Augmented Generation) pulls in only relevant snippets from the distant past if needed.
