# Aimma Deep Matchmaking Questionnaire Data Model & Core Schema
*A High-Dimensional, Context-Aware Profile & Matching Taxonomy for Dynamic Heuristic and Large Language Model (LLM) Vector Architectures.*

---

## 1. Executive Strategy & Technical Integration Map

To power a modern, high-dimensional matchmaking platform, this questionnaire transforms human nuance into machine-readable data structures. It is architected for a dual-engine processing pipeline:

### Heuristic Filter & Graph Processing (Deterministic)
* **Exact Constraints:** Hard Boolean attributes (e.g., `intent_type`, `religious_nikah_required`, `location_radius`, `dietary_halal`) instantly slice the graph network to eliminate non-viable pairings.
* **Scalar Weights:** Linear point scoring computes distances across ordinal parameters like financial expectations, lifestyle pacing, and family timelines.

### LLM Embedded & Semantic Search (Probabilistic)
* **High-Dimensional Embeddings:** Open-ended string fields capture deep narrative context, vocal energy, emotional cadence, and subtext. These are vectorized through dense embedding models (e.g., text-embedding-3-large) to discover hidden, non-obvious affinities across latent spaces.
* **Dynamic Prompt Augmentation:** High-fidelity contextual data is injected directly into LLM scoring prompts (e.g., *"Analyze the semantic tension between User A’s need for intense structural order and User B’s unstructured spontaneous text expression..."*).

```
[User Onboarding]
       │
       ├──► 1. Relationship Intent Topology (Determines Questionnaire Routing)
       │
       ├──► 2. Hard Demographics & Absolute Dealbreakers (Boolean Graph Slicing)
       │
       ├──► 3. Psychological Baseline & Micro-Habits (Heuristic Scoring Tiers)
       │
       └──► 4. Voice / Text Narratives (LLM Semantic Core & Embedding Vectors)
```

---

## 2. Global Core Schema (All Relationship Intents)

### Pillar 1: Base Demographic & Structural Identity
* **Legal First Name:** `[String]`
* **Internal UID:** `[UUIDv4]`
* **Date of Birth:** `[YYYY-MM-DD]` *(Auto-calculate integer age for heuristic distance modeling)*
* **Gender Identity:** `[Dropdown: Male, Female, Non-Binary, Trans-Male, Trans-Female, Custom]`
* **Target Match Gender(s):** `[Array of Dropdown values]`
* **Primary Location:** `[Latitude/Longitude Coordinates]` + `[String: Postal Code, City, Country]`
* **Maximum Relocation/Travel Radius:** `[Integer: Miles/KM]` OR `[Boolean: Globally Open / Digital Nomad]`
* **Ethnic/Cultural Origin Background:** `[Array of Multi-select Options]`

### Pillar 2: Core Psychological & Temperament Engine
* **Attachment Style Profile:** `[Self-Assessment / Proxy Questions mapping to: Secure, Anxious-Preoccupied, Dismissive-Avoidant, Fearful-Avoidant]`
* **Social Energy Baseline:** `[Slider: 1 (Solitary/Deep Introvert) to 10 (High Social Pacing/Extreme Extrovert)]`
* **Cognitive Task Processing:** `[Selection: Hyper-Rational/Analytical vs. Intuitive/Emotional-First vs. Action-Oriented Pragmatist]`
* **Communication Style in Friction:** `[Selection: Immediate confrontation and resolution vs. Cool-down period needed before verbal processing vs. Written/Structured mediation]`

### Pillar 3: Micro-Habits, Daily Rhythms, & Co-habitation
* **Circadian Rhythm Alignment:** `[Selection: Early Morning Lark vs. Balanced/Standard Day vs. Deep Night Owl]`
* **Domestic Order/Cleanliness Index:** `[Slider: 1 (Extreme Minimalism/Highly Sanitized) to 10 (Relaxed/Cluttered/Organic Chaos)]`
* **Substance Profile:**
    * Alcohol Consumption: `[Frequency Dropdown: Never, Rare Social, Weekly, Heavy]`
    * Smoking / Vaping: `[Boolean]`
    * Cannabis / Other Substances: `[Frequency Dropdown]`
* **Pet Compatibility Ecosystem:**
    * Current Pets Owned: `[Array: Cats, Dogs, Birds, Reptiles, None]`
    * Severe Animal Allergies / Strong Aversions: `[Array]`

---

## 3. Modular Intent-Driven Deep Layers

Depending on the core intent selected, the application routes the user through targeted deep questionnaire pipelines.

```
                  ┌───────────────────────┐
                  │  Relationship Intent  │
                  └───────────┬───────────┘
         ┌────────────────────┼────────────────────┐
         ▼                    ▼                    ▼
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│  Casual Dating  │  │  Long-Term Match │  │  Sacred/Nikah  │
└─────────────────┘  └─────────────────┘  └─────────────────┘
```

---

### Layer A: Casual, Short-Term, & Fluid Connections

#### 1. Dynamic Physicality & Chemistry Vectors
* **Primary Love Language Dominance:** `[Ranked Choice: Physical Touch, Words of Affirmation, Quality Time, Acts of Service, Receiving Gifts]`
* **Physical Activity & Movement Intersect:** `[Selection: Sedentary/Leisurely vs. Moderate Hiker/Walker vs. High-Performance Athlete/Gym-Enthusiast]`
* **Spontaneous Adventure Index:** `[Slider: 1 (Meticulously planned itineraries only) to 10 (Drop everything and go to the airport right now)]`

#### 2. Boundaries, Framing, & Communication Cadence
* **Preferred Communication Density:** `[Selection: Constant text-pinging throughout the day vs. Single evening catch-up call vs. Strictly logistics-based messaging]`
* **Exclusivity Protocol Expectations:** `[Dropdown: Exclusively seeing one person at a time during casual phases vs. Multi-dating completely acceptable until explicit consensus]`
* **Financial Splitting Preference for Outings:** `[Dropdown: Alternating rounds vs. Absolute 50/50 down to the cent vs. Initiator pays vs. High-income partner covers]`

#### 3. LLM Open Narratives (Deep Semantic Context)
* **Prompt 1:** "Describe the absolute perfect, unstructured Saturday night encounter you want to experience with a new match. Don't censor details; focus on the vibe, environment, and sensory memories."
    * *System Utility:* Embeds aesthetic alignment, underlying sexual energy profile, and spending thresholds.
* **Prompt 2:** "What is a highly niche topic, weird hobby, or controversial pop-culture hill that you are prepared to die on?"
    * *System Utility:* Extracts specific conversational spark triggers for LLM-driven icebreakers.

---

### Layer B: Long-Term Alignment & Soulmate Architecture

#### 1. Financial Philosophy & Ambition Engine
* **Capital Accumulation vs. Experiential Spending:** `[Slider: 1 (Frugal, heavy retirement optimization, asset investing) to 10 (Live for the present, high luxury travel, lifestyle-first)]`
* **Career Integration Vector:** `[Dropdown: Hustle/High-Growth Executive vs. Balanced 9-to-5/Priority on Leisure vs. Intentionally retiring early/Alternative lifestyle]`
* **Financial Co-mingling Vision:** `[Selection: Complete unification of accounts vs. Hybrid "Yours, Mine, and Ours" model vs. Total separate accounts with shared expenses ledger]`

#### 2. Family Architecture & Kinship Development
* **Procreation Intent Strategy:** `[Dropdown: Absolutely non-negotiably childfree vs. Want children within 1-3 years vs. Want children within 4-7 years vs. Open to adoption/fostering vs. Undecided]`
* **Extended Family Boundary Matrix:** `[Slider: 1 (Complete independence, rare holiday visits, tight boundaries) to 10 (Intergenerational cohabitation, high daily involvement from parents/siblings)]`
* **Parenting Methodological Ideology:** `[Selection: Highly structured/Authoritative/Traditional vs. Gentle/Unstructured/Progressive vs. Focus on early-childhood independence]`

#### 3. Intellectual & Existential Intersect
* **Conversational Friction Demand:** `[Selection: I need high-frequency, passionate intellectual debates and disagreements to stay engaged vs. I value harmony, peace, and consensus above intellectual Sparring]`
* **Core Existential Anchor:** `[Selection: Career & Innovation vs. Creativity & Artistry vs. Community & Service vs. Family Preservation vs. Spiritual Growth]`

#### 4. LLM Open Narratives (Deep Semantic Context)
* **Prompt 1:** "Imagine a severe external crisis hits your family structure 10 years from now (financial loss, unexpected move). Describe how you and your ideal partner tackle the crisis together behind closed doors."
    * *System Utility:* Vectorizes core vulnerability markers, deep resilience profiles, and shadow attachment dynamics.
* **Prompt 2:** "What is a version of yourself that you are actively trying to leave behind, and how does your ideal future partner help support that transformation?"
    * *System Utility:* Identifies actual personal growth metrics to evaluate long-term developmental compatibility.

---

### Layer C: Sacred Unions, Traditional Frameworks, & Muslim Nikah

#### 1. Fiqh, Jurisprudence, & Theological Foundations
* **Islamic Sect/School of Thought Orientation:** `[Dropdown: Sunni, Shia, Just Muslim/Non-denominational, Sufi, Ahmadi]`
* **Adherence Level to Madhhab (Jurisprudence):** `[Dropdown: Flexible/General Principles vs. Strict adherence to Hanafi / Shafi'i / Maliki / Hanbali]`
* **Daily Prayer (Salah) Adherence Tracking:** `[Dropdown: Consistently prays all 5 daily prayers on time vs. Prays regularly but sometimes catches up vs. Prays occasionally (Friday/Eid only) vs. Actively working towards establishing regular prayers]`
* **Halal Lifestyle Matrix:**
    * Dietary Restrictions: `[Dropdown: Strictly Halal certified meats only vs. Halal at home/Zabihah-only vs. Halal friendly/Avoids pork and alcohol vs. No dietary restrictions]`
    * Financial / Riba-Free Constraints: `[Boolean: Require completely Islamic Shariah-compliant financing/avoiding interest]`

#### 2. Modesty, Gender Dynamics, & Public Identity
* **Modesty Observance Tracking (Hijab/Beard/Dress):**
    * For Self: `[Dropdown: Observes Abaya/Niqab vs. Hijab consistently vs. Modest Western/Modern attire vs. Casual Western dress]`
    * For Partner (Requirement Baseline): `[Dropdown: Strict requirement for Hijab/Niqab vs. Preferences modest modern attire vs. Complete freedom/No requirement]`
* **Free-Mixing & Social Boundary Constraints:** `[Selection: Avoids non-essential mixing with the opposite gender completely vs. Comfortable in professional settings only vs. Comfortable in casual/co-ed social gatherings]`

#### 3. Legal, Contractual, & Cultural Nikah Architecture
* **Wali (Guardian) Involvement Strategy:** `[Dropdown: Wali is involved from Day 1 of matching and screens communication vs. Wali is introduced once personal compatibility is confirmed vs. Independent decision-making prior to marriage setup]`
* **Mahr (Dower) Philosophy:** `[Selection: Symbolic/Spiritual Mahr prioritized vs. Standard cultural/financial asset protection baseline vs. Deferred Mahr structure focused on future security]`
* **Polygyny Stance (If applicable):** `[Dropdown: Intentionally looking for a polygynous arrangement vs. Open to discussion vs. Strictly monogamous marriage contract clause required]`

#### 4. LLM Open Narratives (Deep Semantic Context)
* **Prompt 1:** "Detail how you envision balancing Islamic spiritual goals (Hajj, Umrah, continuous learning, teaching children) with your worldly career and personal ambitions."
    * *System Utility:* Detects precise spiritual-material alignment matrices, filtering out superficial religious compliance from true lifestyle goals.
* **Prompt 2:** "How do you define the roles and structural rights/responsibilities of a husband and a wife when managing a household? Be specific regarding financial maintenance, emotional labor, and leadership."
    * *System Utility:* Evaluates traditional vs. modern egalitarian interpretations of marital contracts and prevents acute structural friction.

---

## 4. Advanced System Scoring Weights & Search Execution Strategy

### The Dual-Pass Engine Execution Flow

```
Raw User Input
     │
     ▼
┌────────────────────────────────────────┐
│ PASS 1: Deterministic Heuristic Filter │
│ (Slices out impossible graph nodes)    │
└────────────────────┬───────────────────┘
                     │
                     ▼   [Filtered Candidate Pool]
┌────────────────────────────────────────┐
│ PASS 2: Multi-Vector Embedding Search  │
│ (Calculates Cosine Similarity Metrics) │
└────────────────────┬───────────────────┘
                     │
                     ▼   [Top N Candidates]
┌────────────────────────────────────────┐
│ PASS 3: LLM Cross-Context Evaluator     │
│ (Generates Final Matching Affinities)  │
└────────────────────┬───────────────────┘
                     │
                     ▼
             Curated Top Match
```

### Technical Schema Configuration

To store this information cleanly within PostgreSQL (using `pgvector`) or MongoDB collections, the structural weights are assigned across three operating metrics:

| Field Token ID | Input Type | Matching Engine Type | System Weight / Hard Threshold |
| :--- | :--- | :--- | :--- |
| `intent_type` | Multi-Choice Enum | **Deterministic Graph** | `CRITICAL HARD FILTER` (Zero-cross mismatch) |
| `relocation_open` | Boolean Switch | **Deterministic Graph** | `CRITICAL HARD FILTER` |
| `salah_frequency` | Ordinal Scale | **Weighted Heuristic** | High Weight (35% of Theological Score) |
| `financial_axis` | Linear Slider | **Weighted Heuristic** | Moderate Weight (20% of Lifestyle Score) |
| `open_narrative_1` | Long String | **Semantic Vector** | Dense Array Mapping (`text-embedding-3-large`) |
| `open_narrative_2` | Long String | **Semantic Vector** | Dense Array Mapping (`text-embedding-3-large`) |
