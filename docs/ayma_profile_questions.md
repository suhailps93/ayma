# Ayma Profile Questions (1:1 Mirror)

Source of truth: `docs/ayma_profile_questions.json`.

Sync rule: Markdown must stay 1:1 with this JSON for field IDs, order, required, heuristic_usable, sensitive_flag, default_visibility, and llm_wiki_bucket.

## Objective
Maximize profile completeness by collecting high-signal relationship data with explicit consent and safe handling of sensitive attributes.

## Scoring Weights
- core_matchability: 40
- intent_and_readiness: 20
- lifestyle_compatibility: 15
- values_and_family_alignment: 15
- depth_and_authenticity: 10

## Storage Policy
- Non-sensitive default visibility: `public`
- Sensitive default visibility: `private`
- Sensitive fields can be made public only by explicit user choice
- AI summary field is always included in public payload

## Ordered Public Payload
- basic_identity
- location_mobility
- physical_lifestyle
- education_career
- financial_compatibility
- intent_readiness
- children_parenting
- communication_conflict
- social_life
- partner_preferences
- depth_authenticity
- ai_profile_summary

## Questions
| # | id | section | type | required | heuristic_usable | sensitive_flag | consent_required | default_visibility | llm_wiki_bucket | priority | partner_preference_pair_id |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | age | basic_identity | number | true | true | false | false | public | public_profile | high | preferred_age_range |
| 2 | gender_identity | basic_identity | single_select | true | true | true | true | private | private_sensitive | high | preferred_gender_identities |
| 3 | location_city | location_mobility | location | true | true | false | false | public | public_profile | high |  |
| 4 | max_distance_km | location_mobility | number | true | true | false | false | public | public_profile | high |  |
| 5 | willing_to_relocate | location_mobility | single_select | true | true | false | false | public | public_profile | high | partner_relocation_expectation |
| 6 | height_cm | physical_lifestyle | number | true | true | false | false | public | public_profile | high | preferred_height_range_cm |
| 7 | weight_kg | physical_lifestyle | number | false | true | false | true | public | public_profile | medium | preferred_weight_range_kg |
| 8 | skin_tone | sensitive_attributes | single_select | false | false | true | true | private | private_sensitive | low | preferred_skin_tone |
| 9 | race | sensitive_attributes | multi_select | false | false | true | true | private | private_sensitive | medium | preferred_race_ethnicity |
| 10 | religion | values_religion_culture | single_select | false | false | true | true | private | private_sensitive | high | preferred_religion |
| 11 | religious_practice_level | values_religion_culture | single_select | false | true | true | true | private | private_sensitive | medium | preferred_religious_practice_level |
| 12 | caste | sensitive_attributes | text | false | false | true | true | private | private_sensitive | low | preferred_caste |
| 13 | sub_caste | sensitive_attributes | text | false | false | true | true | private | private_sensitive | low | preferred_sub_caste |
| 14 | education_level | education_career | single_select | true | true | false | false | public | public_profile | high | preferred_education_level |
| 15 | occupation | education_career | text | true | true | false | false | public | public_profile | high | preferred_occupation_categories |
| 16 | career_stage | education_career | single_select | true | true | false | false | public | public_profile | medium | preferred_career_stage |
| 17 | income_band | financial_compatibility | single_select | false | true | true | true | private | private_sensitive | medium | preferred_income_band |
| 18 | relationship_intent | intent_readiness | text | true | true | false | false | public | public_profile | high | preferred_relationship_intent |
| 19 | timeline_for_commitment | intent_readiness | single_select | true | true | false | false | public | public_profile | high | preferred_timeline_for_commitment |
| 20 | marital_status | intent_readiness | single_select | true | true | false | false | public | public_profile | high | preferred_marital_status |
| 21 | has_children | children_parenting | boolean | true | true | false | false | public | public_profile | high | partner_ok_with_children |
| 22 | wants_children | children_parenting | single_select | true | true | false | false | public | public_profile | high | partner_wants_children |
| 23 | diet | physical_lifestyle | single_select | true | true | false | false | public | public_profile | medium | preferred_partner_diet |
| 24 | smoking_status | physical_lifestyle | single_select | true | true | false | false | public | public_profile | high | partner_smoking_tolerance |
| 25 | alcohol_status | physical_lifestyle | single_select | true | true | false | false | public | public_profile | high | partner_alcohol_tolerance |
| 26 | family_type | family_background | single_select | true | true | false | false | public | public_profile | high | preferred_family_type |
| 27 | family_values | family_background | text | false | false | false | false | public | public_profile | medium |  |
| 28 | past_relationship_count | relationship_history | number | false | false | true | true | private | private_sensitive | low |  |
| 29 | past_relationship_learnings | relationship_history | text | false | false | true | true | private | private_sensitive | medium |  |
| 30 | communication_style | communication_conflict | multi_select | true | true | false | false | public | public_profile | medium | preferred_partner_communication_style |
| 31 | conflict_style | communication_conflict | single_select | true | true | false | false | public | public_profile | medium | preferred_partner_conflict_style |
| 32 | friends_social_style | social_life | single_select | false | false | false | false | public | public_profile | low | preferred_partner_social_style |
| 33 | has_pets | social_life | boolean | false | true | false | false | public | public_profile | low | partner_pet_tolerance |
| 34 | pet_details | social_life | text | false | false | false | false | public | public_profile | low |  |
| 35 | partner_non_negotiables | partner_preferences | text | true | true | false | false | public | public_profile | high |  |
| 36 | partner_must_haves | partner_preferences | text | true | true | false | false | public | public_profile | high |  |
| 37 | preferred_age_range | partner_preferences | range | true | true | false | false | public | public_profile | high | age |
| 38 | preferred_height_range_cm | partner_preferences | range | false | true | false | false | public | public_profile | medium | height_cm |
| 39 | preferred_religion | partner_preferences_sensitive | multi_select | false | false | true | true | private | private_sensitive | medium | religion |
| 40 | preferred_caste | partner_preferences_sensitive | text | false | false | true | true | private | private_sensitive | low | caste |
| 41 | preferred_sub_caste | partner_preferences_sensitive | text | false | false | true | true | private | private_sensitive | low | sub_caste |
| 42 | preferred_race_ethnicity | partner_preferences_sensitive | multi_select | false | false | true | true | private | private_sensitive | low | race |
| 43 | bio_relationship_offer | depth_authenticity | text | true | false | false | false | public | public_profile | medium |  |
| 44 | bio_relationship_need | depth_authenticity | text | true | false | false | false | public | public_profile | medium |  |
| 45 | ai_profile_summary | ai_profile_summary | generated_text | true | false | false | false | public | public_profile | high |  |

## Heuristic Policy
Allowed in ranking (by section):
- basic_identity
- location_mobility
- physical_lifestyle
- education_career
- financial_compatibility
- intent_readiness
- children_parenting
- communication_conflict
- partner_preferences

Blocked from default ranking (by section):
- sensitive_attributes
- partner_preferences_sensitive
- family_background
- relationship_history
- social_life
- depth_authenticity

Sensitive usage rule:
- Sensitive fields must never be used for default ranking. They can only be used as explicit user-selected filters with consent.
