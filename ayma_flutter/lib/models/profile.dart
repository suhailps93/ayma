class UserProfile {
  final String id;
  final String displayName;
  final String? profilePublic;
  final String? profilePrivate;
  final bool profilePublicLocked;
  final String agentName;
  final String voicePreference;
  final Map<String, dynamic> matchingPrefs;
  final int? age;
  final String? gender;
  final String? locationRegion;
  final String communityProfile;
  final bool onboardingComplete;
  final bool matchingPaused;

  const UserProfile({
    required this.id,
    required this.displayName,
    this.profilePublic,
    this.profilePrivate,
    required this.profilePublicLocked,
    required this.agentName,
    required this.voicePreference,
    required this.matchingPrefs,
    this.age,
    this.gender,
    this.locationRegion,
    required this.communityProfile,
    required this.onboardingComplete,
    required this.matchingPaused,
  });

  factory UserProfile.fromMap(Map<String, dynamic> m) => UserProfile(
    id:                   m['id'] as String,
    displayName:          (m['display_name'] as String?) ?? '',
    profilePublic:        m['profile_public'] as String?,
    profilePrivate:       m['profile_private'] as String?,
    profilePublicLocked:  (m['profile_public_locked'] as bool?) ?? false,
    agentName:            (m['agent_name'] as String?) ?? 'Ayma',
    voicePreference:      (m['voice_preference'] as String?) ?? 'Charon',
    matchingPrefs:        (m['matching_prefs'] as Map<String, dynamic>?) ?? {},
    age:                  m['age'] as int?,
    gender:               m['gender'] as String?,
    locationRegion:       m['location_region'] as String?,
    communityProfile:     (m['community_profile'] as String?) ?? 'dating_standard',
    onboardingComplete:   (m['onboarding_complete'] as bool?) ?? false,
    matchingPaused:       (m['matching_paused'] as bool?) ?? false,
  );

  UserProfile copyWith({
    String? displayName,
    String? profilePublic,
    String? profilePrivate,
    bool? profilePublicLocked,
    String? agentName,
    String? voicePreference,
    Map<String, dynamic>? matchingPrefs,
    int? age,
    String? gender,
    String? locationRegion,
    bool? onboardingComplete,
    bool? matchingPaused,
  }) => UserProfile(
    id:                   id,
    displayName:          displayName ?? this.displayName,
    profilePublic:        profilePublic ?? this.profilePublic,
    profilePrivate:       profilePrivate ?? this.profilePrivate,
    profilePublicLocked:  profilePublicLocked ?? this.profilePublicLocked,
    agentName:            agentName ?? this.agentName,
    voicePreference:      voicePreference ?? this.voicePreference,
    matchingPrefs:        matchingPrefs ?? this.matchingPrefs,
    age:                  age ?? this.age,
    gender:               gender ?? this.gender,
    locationRegion:       locationRegion ?? this.locationRegion,
    communityProfile:     communityProfile,
    onboardingComplete:   onboardingComplete ?? this.onboardingComplete,
    matchingPaused:       matchingPaused ?? this.matchingPaused,
  );
}
