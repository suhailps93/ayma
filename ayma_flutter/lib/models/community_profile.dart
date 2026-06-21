// Community profile configs: question sets, prompt tone, and completeness weights per matchmaking context.
/// Community Profile System
///
/// Each CommunityProfile defines the cultural/contextual configuration
/// for a matchmaking context (Western dating, Indian arranged marriage, etc.).
/// The [id] maps directly to the `community_profile` column in the DB.
class CommunityProfile {
  final String id;
  final String displayName;
  final String shortDescription;
  final String emoji;

  /// Instructions injected into Ayma's personality for this community context.
  final String agentPersonality;

  /// Ordered list of question IDs relevant to this community.
  final List<String> questionIds;

  /// Subset of [questionIds] that are required (must be answered).
  final Set<String> requiredQuestionIds;

  /// Questions that are sensitive — asked later in conversation.
  final Set<String> sensitiveQuestionIds;

  /// Matching dimensions to weight heavily for this community.
  final List<String> matchingDimensions;

  final bool isArrangedMarriage;
  final bool familyInvolved;

  /// Background cultural context injected into the AI system prompt.
  final String culturalNotes;

  const CommunityProfile({
    required this.id,
    required this.displayName,
    required this.shortDescription,
    required this.emoji,
    required this.agentPersonality,
    required this.questionIds,
    required this.requiredQuestionIds,
    required this.sensitiveQuestionIds,
    required this.matchingDimensions,
    required this.isArrangedMarriage,
    required this.familyInvolved,
    required this.culturalNotes,
  });
}

/// Central registry of all known community profiles.
class CommunityProfiles {
  CommunityProfiles._();

  // ── 1. Western / US Dating ─────────────────────────────────────────────────

  static const datingWestern = CommunityProfile(
    id: 'dating_western',
    displayName: 'Western Dating',
    shortDescription: 'Casual to committed — inclusive, modern matchmaking',
    emoji: '💛',
    agentPersonality:
        'Be warm, casual, witty, and open-minded. Celebrate individuality. '
        'Avoid assumptions about gender roles or family expectations. '
        'Make the user feel comfortable sharing their authentic self.',
    questionIds: [
      'age',
      'location_city',
      'height_cm',
      'education_level',
      'occupation',
      'relationship_intent',
      'timeline_for_commitment',
      'marital_status',
      'has_children',
      'wants_children',
      'smoking_status',
      'alcohol_status',
      'diet',
      'family_type',
      'communication_style',
      'conflict_style',
      'bio_relationship_offer',
      'bio_relationship_need',
      'partner_non_negotiables',
      'partner_must_haves',
      'preferred_age_range',
      'gender_identity',
      'sexual_orientation',
      'religion',
      'religious_practice_level',
      'income_band',
      'career_stage',
      'friends_social_style',
      'has_pets',
      'past_relationship_learnings',
      'preferred_religion',
      'max_distance_km',
      'willing_to_relocate',
    ],
    requiredQuestionIds: {
      'age',
      'location_city',
      'relationship_intent',
      'timeline_for_commitment',
      'marital_status',
      'has_children',
      'wants_children',
      'partner_non_negotiables',
      'partner_must_haves',
      'preferred_age_range',
    },
    sensitiveQuestionIds: {
      'gender_identity',
      'sexual_orientation',
      'religion',
      'religious_practice_level',
      'income_band',
      'past_relationship_learnings',
    },
    matchingDimensions: [
      'relationship_intent',
      'lifestyle_compatibility',
      'communication_style',
      'values_alignment',
      'attraction',
    ],
    isArrangedMarriage: false,
    familyInvolved: false,
    culturalNotes:
        'Western dating context: individual autonomy is paramount. '
        'Users are self-selecting and self-presenting. '
        'Avoid assuming any particular family structure or religious obligation.',
  );

  // ── 2. Indian Arranged Marriage ────────────────────────────────────────────

  static const arrangedIndia = CommunityProfile(
    id: 'arranged_india',
    displayName: 'Indian Arranged Marriage',
    shortDescription: 'Family-supported matchmaking rooted in Indian culture',
    emoji: '🪷',
    agentPersonality:
        'Be respectful, formal when needed, and family-aware. '
        'Understand that the family often plays a central role in the decision. '
        'Use warm, dignified language. Respect religious and caste sensitivities — '
        'ask gently and always make clear that sharing is optional. '
        'Frame matching in terms of long-term compatibility and family harmony.',
    questionIds: [
      'age',
      'location_city',
      'height_cm',
      'education_level',
      'occupation',
      'career_stage',
      'income_band',
      'family_income_band',
      'nri_status',
      'state_of_origin',
      'mother_tongue',
      'religion',
      'religious_sect',
      'caste',
      'sub_caste',
      'gotra',
      'manglik_status',
      'kundali_match_required',
      'marital_status',
      'has_children',
      'wants_children',
      'family_type',
      'family_type_preference',
      'family_values',
      'diet',
      'smoking_status',
      'alcohol_status',
      'relationship_intent',
      'timeline_for_commitment',
      'communication_style',
      'partner_non_negotiables',
      'partner_must_haves',
      'preferred_age_range',
      'preferred_religion',
      'preferred_caste',
      'preferred_sub_caste',
      'skin_tone',
      'max_distance_km',
      'willing_to_relocate',
    ],
    requiredQuestionIds: {
      'age',
      'location_city',
      'education_level',
      'occupation',
      'nri_status',
      'state_of_origin',
      'mother_tongue',
      'religion',
      'marital_status',
      'has_children',
      'wants_children',
      'family_type',
      'relationship_intent',
      'timeline_for_commitment',
      'partner_non_negotiables',
      'partner_must_haves',
      'preferred_age_range',
    },
    sensitiveQuestionIds: {
      'caste',
      'sub_caste',
      'gotra',
      'manglik_status',
      'kundali_match_required',
      'religious_sect',
      'family_income_band',
      'income_band',
      'skin_tone',
    },
    matchingDimensions: [
      'religion',
      'caste_compatibility',
      'family_values',
      'education_career',
      'lifestyle_compatibility',
      'location_preference',
    ],
    isArrangedMarriage: true,
    familyInvolved: true,
    culturalNotes:
        'Indian arranged marriage context: family approval is central. '
        'Caste, gotra, religion, and regional origin are often important filters. '
        'Kundali/horoscope matching may be mandatory for Hindu users. '
        'NRI vs India-based distinction matters for compatibility. '
        'Joint vs nuclear family preference is a key dimension. '
        'Handle caste and sub-caste with sensitivity — always optional.',
  );

  // ── 3. Muslim Matrimonial ──────────────────────────────────────────────────

  static const matrimonialMuslim = CommunityProfile(
    id: 'matrimonial_muslim',
    displayName: 'Muslim Matrimonial',
    shortDescription: 'Nikah-focused, Islamic values-aligned matchmaking',
    emoji: '☪️',
    agentPersonality:
        'Be respectful, dignified, and Islamic-values-aware. '
        'Use appropriate language — "marriage" not "dating", '
        '"spouse" or "partner" as appropriate. '
        'Understand that religious practice, halal lifestyle, '
        'and family/community approval matter deeply. '
        'Ask about sensitive topics (like polygamy openness) very delicately '
        'and only once trust is established.',
    questionIds: [
      'age',
      'location_city',
      'height_cm',
      'education_level',
      'occupation',
      'career_stage',
      'income_band',
      'religion',
      'religious_sect',
      'religious_practice_level',
      'prayer_frequency',
      'hijab_preference',
      'beard_preference',
      'halal_diet_strict',
      'mahram_required',
      'nikah_type',
      'marital_status',
      'has_children',
      'wants_children',
      'family_type',
      'family_values',
      'diet',
      'smoking_status',
      'alcohol_status',
      'relationship_intent',
      'timeline_for_commitment',
      'communication_style',
      'partner_non_negotiables',
      'partner_must_haves',
      'preferred_age_range',
      'max_distance_km',
      'willing_to_relocate',
      'polygamy_openness',
    ],
    requiredQuestionIds: {
      'age',
      'location_city',
      'religion',
      'religious_sect',
      'religious_practice_level',
      'marital_status',
      'has_children',
      'wants_children',
      'relationship_intent',
      'timeline_for_commitment',
      'partner_non_negotiables',
      'partner_must_haves',
      'preferred_age_range',
      'nikah_type',
      'halal_diet_strict',
    },
    sensitiveQuestionIds: {
      'polygamy_openness',
      'mahram_required',
      'income_band',
      'religious_sect',
    },
    matchingDimensions: [
      'religious_practice',
      'sect_compatibility',
      'lifestyle_halal',
      'family_values',
      'education_career',
      'location_preference',
    ],
    isArrangedMarriage: true,
    familyInvolved: true,
    culturalNotes:
        'Islamic matrimonial context: the goal is nikah (marriage). '
        'Sect (Sunni/Shia/Ahmadi) compatibility is important. '
        'Halal diet and prayer practice are lifestyle filters. '
        'Hijab and beard preferences indicate religious observance levels. '
        'Mahram/chaperone requirement applies for some users. '
        'Polygamy should only be discussed if user raises it or consents to the topic.',
  );

  // ── 4. West African Arranged Marriage ─────────────────────────────────────

  static const arrangedAfricaWest = CommunityProfile(
    id: 'arranged_africa_west',
    displayName: 'West African Marriage',
    shortDescription: 'Nigeria & Ghana — community-rooted, family-blessed unions',
    emoji: '🌍',
    agentPersonality:
        'Be warm, respectful of elders and community, and culturally aware. '
        'Understand that marriage is often a union of families, not just individuals. '
        'Tribal/ethnic identity and religious faith are important. '
        'Bride price (lobola/bride price) is a cultural reality — handle with dignity. '
        'Celebrate cultural pride while being inclusive.',
    questionIds: [
      'age',
      'location_city',
      'height_cm',
      'education_level',
      'occupation',
      'career_stage',
      'income_band',
      'religion',
      'religious_practice_level',
      'tribe_ethnicity',
      'language_spoken',
      'lobola_expectation',
      'family_approval_importance',
      'marital_status',
      'has_children',
      'wants_children',
      'family_type',
      'family_values',
      'diet',
      'smoking_status',
      'alcohol_status',
      'relationship_intent',
      'timeline_for_commitment',
      'communication_style',
      'partner_non_negotiables',
      'partner_must_haves',
      'preferred_age_range',
      'max_distance_km',
      'willing_to_relocate',
    ],
    requiredQuestionIds: {
      'age',
      'location_city',
      'religion',
      'tribe_ethnicity',
      'marital_status',
      'has_children',
      'wants_children',
      'relationship_intent',
      'timeline_for_commitment',
      'partner_non_negotiables',
      'partner_must_haves',
      'preferred_age_range',
      'family_approval_importance',
    },
    sensitiveQuestionIds: {
      'lobola_expectation',
      'income_band',
      'tribe_ethnicity',
    },
    matchingDimensions: [
      'religion',
      'tribe_compatibility',
      'family_values',
      'education_career',
      'lifestyle_compatibility',
      'location_preference',
    ],
    isArrangedMarriage: true,
    familyInvolved: true,
    culturalNotes:
        'West African marriage context: family and community approval is central. '
        'Tribal and ethnic identity (Yoruba, Igbo, Hausa, Akan, etc.) matters. '
        'Christianity and Islam are the dominant faiths. '
        'Bride price/lobola is a respected tradition — ask respectfully. '
        'Language spoken at home (Yoruba, Igbo, Twi, etc.) is an important cultural marker.',
  );

  // ── 5. LGBTQ+ Inclusive Dating ─────────────────────────────────────────────

  static const datingLgbtq = CommunityProfile(
    id: 'dating_lgbtq',
    displayName: 'LGBTQ+ Dating',
    shortDescription: 'Inclusive, affirming matchmaking for all identities',
    emoji: '🏳️‍🌈',
    agentPersonality:
        'Be deeply affirming, warm, and identity-aware. '
        'Use inclusive language, honour chosen names and pronouns without question. '
        'Never assume gender or sexuality. '
        'Understand that transition status and relationship structures vary widely. '
        'Make the user feel completely safe to be themselves.',
    questionIds: [
      'age',
      'location_city',
      'height_cm',
      'education_level',
      'occupation',
      'career_stage',
      'income_band',
      'gender_identity',
      'sexual_orientation',
      'pronouns',
      'relationship_intent',
      'relationship_structure',
      'timeline_for_commitment',
      'marital_status',
      'has_children',
      'wants_children',
      'smoking_status',
      'alcohol_status',
      'diet',
      'communication_style',
      'conflict_style',
      'bio_relationship_offer',
      'bio_relationship_need',
      'partner_non_negotiables',
      'partner_must_haves',
      'preferred_age_range',
      'religion',
      'religious_practice_level',
      'friends_social_style',
      'has_pets',
      'past_relationship_learnings',
      'max_distance_km',
      'willing_to_relocate',
      'transition_status',
    ],
    requiredQuestionIds: {
      'age',
      'location_city',
      'gender_identity',
      'sexual_orientation',
      'pronouns',
      'relationship_intent',
      'relationship_structure',
      'timeline_for_commitment',
      'partner_non_negotiables',
      'partner_must_haves',
      'preferred_age_range',
    },
    sensitiveQuestionIds: {
      'transition_status',
      'income_band',
      'religion',
      'past_relationship_learnings',
    },
    matchingDimensions: [
      'identity_compatibility',
      'relationship_structure',
      'lifestyle_compatibility',
      'values_alignment',
      'communication_style',
      'location_preference',
    ],
    isArrangedMarriage: false,
    familyInvolved: false,
    culturalNotes:
        'LGBTQ+ dating context: identity is self-defined and must be respected fully. '
        'Relationship structures beyond monogamy (polyamory, open relationships) are valid options. '
        'Transition status is deeply personal — only ask if volunteered or explicitly permitted. '
        'Pronoun use should be strictly observed throughout the conversation.',
  );

  // ── 6. BFF / Platonic Friendship ──────────────────────────────────────────

  static const friendsBff = CommunityProfile(
    id: 'friends_bff',
    displayName: 'Find Your People',
    shortDescription: 'Genuine friendships — no romantic intentions',
    emoji: '🤝',
    agentPersonality:
        'Be warm, playful, and zero-pressure. '
        'This is about finding real friends, not dates. '
        'Celebrate shared interests, humor, and vibe-matching. '
        'Ask about hobbies, lifestyle, and what makes someone a good friend to them. '
        'Never assume romantic interest.',
    questionIds: [
      'age',
      'location_city',
      'occupation',
      'education_level',
      'friends_social_style',
      'hobbies_interests',
      'communication_style',
      'has_pets',
      'diet',
      'smoking_status',
      'alcohol_status',
      'preferred_age_range',
      'max_distance_km',
      'willing_to_relocate',
    ],
    requiredQuestionIds: {
      'age',
      'location_city',
      'friends_social_style',
      'hobbies_interests',
      'preferred_age_range',
    },
    sensitiveQuestionIds: {},
    matchingDimensions: [
      'shared_interests',
      'social_style',
      'communication_style',
      'lifestyle_compatibility',
      'location_preference',
    ],
    isArrangedMarriage: false,
    familyInvolved: false,
    culturalNotes:
        'Platonic friendship context: the goal is genuine human connection, '
        'not romance. Focus on shared activities, values, and vibe. '
        'Treat every question as "what makes someone a great friend to you."',
  );

  // ── 7. Career / Cofounder Network ─────────────────────────────────────────

  static const careerNetwork = CommunityProfile(
    id: 'career_network',
    displayName: 'Cofounder & Collaborator',
    shortDescription: 'Find business partners, cofounders, and collaborators',
    emoji: '🚀',
    agentPersonality:
        'Be sharp, direct, and intellectually curious. '
        'This person is looking for a cofounder, business partner, or collaborator — '
        'not a date or a friend. '
        'Ask about their domain, stage, ambition level, working style, and what they\'re building. '
        'Think like a sharp investor or talent connector: who would they work well with? '
        'Focus on complementary skills, shared vision, and execution style.',
    questionIds: [
      'age',
      'location_city',
      'occupation',
      'career_stage',
      'income_band',
      'education_level',
      'startup_stage',
      'domain_expertise',
      'skills_offered',
      'skills_needed',
      'work_style',
      'ambition_level',
      'commitment_level',
      'communication_style',
      'willing_to_relocate',
      'max_distance_km',
    ],
    requiredQuestionIds: {
      'age',
      'location_city',
      'occupation',
      'career_stage',
      'domain_expertise',
      'skills_offered',
      'skills_needed',
      'work_style',
      'ambition_level',
    },
    sensitiveQuestionIds: {
      'income_band',
      'commitment_level',
    },
    matchingDimensions: [
      'domain_complementarity',
      'work_style',
      'ambition_alignment',
      'skills_fit',
      'location_preference',
    ],
    isArrangedMarriage: false,
    familyInvolved: false,
    culturalNotes:
        'Career/cofounder context: match on complementary skills, execution style, '
        'and shared ambition level. Domain expertise matters more than personality vibe. '
        'Respect confidentiality — do not share startup details without consent.',
  );

  // ── Legacy alias ────────────────────────────────────────────────────────────

  /// Alias for backward compatibility with the existing 'dating_standard' DB value.
  static const datingStandard = datingWestern;

  // ── Registry ────────────────────────────────────────────────────────────────

  /// All available community profiles, in display order.
  static const List<CommunityProfile> all = [
    datingWestern,
    arrangedIndia,
    matrimonialMuslim,
    arrangedAfricaWest,
    datingLgbtq,
    friendsBff,
    careerNetwork,
  ];

  /// Look up a profile by [id]. Falls back to [datingWestern] for unknown IDs.
  static CommunityProfile forId(String id) {
    // Handle legacy DB value
    if (id == 'dating_standard') return datingWestern;
    return all.firstWhere(
      (p) => p.id == id,
      orElse: () => datingWestern,
    );
  }

  /// Suggest the best community based on location and device locale.
  static CommunityProfile suggestFromLocation(String? locationRegion) {
    final loc = (locationRegion ?? '').toLowerCase();
    if (loc.contains('india') ||
        loc.contains('mumbai') ||
        loc.contains('delhi') ||
        loc.contains('bengaluru') ||
        loc.contains('chennai') ||
        loc.contains('hyderabad') ||
        loc.contains('kolkata')) {
      return arrangedIndia;
    }
    if (loc.contains('nigeria') ||
        loc.contains('ghana') ||
        loc.contains('lagos') ||
        loc.contains('abuja') ||
        loc.contains('accra')) {
      return arrangedAfricaWest;
    }
    return datingWestern;
  }
}
