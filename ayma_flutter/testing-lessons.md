# Flutter Testing Lessons

This file is the persistent test memory. The test sub-agent reads it before every test run
and appends to it after every test run. Never truncate or rewrite — always append.

## Format

Each entry:
```
### [DATE] [SCREEN/FEATURE]
- Tested: what interaction was driven
- Outcome: pass / fail
- Root cause (if fail): what was actually wrong
- Fix applied: what agent was called, what changed
- Lesson: what to check for next time
```

---

## Entries

<!-- Test sub-agent appends below this line -->
### 2026-05-24 profile page refresh
- Tested: flutter analyze on `lib/screens/profile/profile_screen.dart` and `lib/providers/providers.dart`
- Outcome: pass
- Root cause (if fail): n/a
- Fix applied: updated `ProfileScreen` to use the same public-profile snapshot and insights sources as Explore/Insights; added a public profile provider and invalidation on save/upload
- Lesson: keep the self profile and viewed profile paths on the same Firestore data shape so gallery/story refresh together
