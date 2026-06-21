---
name: reddit_xai_workflows
description: Cutting-edge developer workflows synthesized from Reddit discussions and xAI Grok best practices
---

# Modern AI Workflow Best Practices (Reddit & xAI)

Synthesized from the developer community and xAI's best practices, apply these workflows to optimize AI coding sessions.

## 1. The Scratchpad & Memory Approach
*   **Prevent Mistake Loops**: When you encounter a bug or architectural edge-case, document it permanently in a `scratchpad` or context file. Do not let the agent repeat the same mistake across different sessions.
*   **Focused Context**: While massive context windows are available, avoid bloated `agents.md` files. Provide modular, structured context so the agent focuses purely on the relevant system boundaries.

## 2. Constrained Autonomy & "Plan-First" Execution
*   **Plan, Review, Execute**: Modeled after xAI's Grok Build workflow, never jump straight into blind code generation for complex tasks. First, propose a detailed plan or `spec.md`. Only execute the code after the human-in-the-loop has approved the plan.
*   **Role-Playing for Quality**: When requesting complex optimizations, explicitly instruct the agent to adopt a role (e.g., "Act as a Senior Systems Architect; optimize this algorithm for safety and Big-O efficiency").

## 3. Context Management (xAI Grok Lessons)
*   **Massive Context Strengths**: Use massive context window capabilities (like Grok's 2M token limit) for holistic architectural analysis—dumping entire repositories or stack traces into context to diagnose deep systemic issues without needing to chunk code.
*   **Abandon Corrupted Threads**: If the agent hallucinates deeply or heads down a fundamentally incorrect path in a long session, **do not try to argue with it or fix the corrupted context**. It is faster and cheaper to clear the context, start a fresh thread, and provide the correct guidance upfront.

## 4. Multi-Model Strategy
*   **Optimize for the Task**: Differentiate between "heavy lifting" (strategic planning, complex refactors) and "routine execution" (fast edits, boilerplate generation). Use the most powerful models for planning, but execute repetitive, low-latency tasks with faster, cheaper models.
