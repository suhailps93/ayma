# Ayma Memory System

> **Status:** LLM Wiki live. Traits removed. Raw audit log kept.
>
> [← Back to Architecture](ARCHITECTURE.md)

---

## How It Works

After every voice or text turn, Flutter sends the last 10 lines of conversation to `POST /post-turn`. Cloud Run runs **4 parallel Gemini calls**, each doing an intelligent upsert on one wiki field in the user's Firestore document. At the start of the next session, `/bootstrap` reads those 4 fields and injects them directly into the Gemini Live system prompt.

No embeddings. No vector search. No subcollection reads at bootstrap. The wiki is always current, always compact, always injected in full.

---

## The 4 Wiki Fields

All stored on `users/{uid}` (flat fields, not a subcollection):

| Field | What it captures | Max size |
|---|---|---|
| `wiki_about_me` | Personality, communication style, hobbies, lifestyle | ~150 words |
| `wiki_context` | Current life phase, recent events, emotional state | ~100 words |
| `wiki_preferences` | What they want in a partner, dealbreakers, relationship goals | ~150 words |
| `wiki_matching` | Structured specs for matching: age range, values, lifestyle, hard dealbreakers | ~150 words |

---

## The Upsert Mechanism

Each Gemini call receives:
1. The **current content** of that wiki field (or empty string on first session)
2. The **new conversation snippet** (last 10 lines)

And is instructed to:
- **Preserve** accurate existing info
- **Correct** anything the user has contradicted
- **Add** newly revealed facts
- **Prune** redundant or noisy content
- **Never hallucinate** — only facts explicitly stated

This means contradictions are resolved automatically. If a user said "I want kids" in session 1 and "I'm not sure about kids anymore" in session 10, `wiki_preferences` gets updated to reflect the current state.

---

## What Gets Injected at Bootstrap

`/bootstrap` reads the user document (single Firestore read) and injects all 4 wiki fields into the system prompt in this order:

```
## About {name}
{wiki_about_me}

## {name}'s Current Life Context
{wiki_context}

## What {name} Is Looking For
{wiki_preferences}

## {name}'s Matching Profile
{wiki_matching}
```

Total context: ~500 tokens of dense, deduplicated, contradiction-resolved profile. Far more useful than 40 raw bullet points.

---

## Raw Audit Log

Each `/post-turn` call also writes the raw conversation snippet to `users/{uid}/memories/{id}`. This is never injected into any prompt — it exists purely as a debug trail to verify what the AI saw and extracted. The memories subcollection is write-only from Cloud Run.

---

## Roadmap

- [ ] Surface wiki fields in the Insights screen (currently shows `profile_public` etc., not wiki fields)
- [ ] Use `wiki_matching` as primary input for Phase 2 matching engine
