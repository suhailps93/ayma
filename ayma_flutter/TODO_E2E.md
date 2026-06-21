# E2E Status

All items below are implemented and code-complete. No blocking issues remain.

- [x] Chat auto-scroll opens at latest message
  - Implemented via `_scrollToBottom()` called on new transcript entries and initial load.

- [x] Voice does not auto-start on chat open
  - Chat opens in `disconnected` state; voice only starts on explicit mic tap.

- [x] "Your Story" / Private Profile population works end-to-end
  - Wiki fields (`wiki_about_me`, `wiki_context`, `wiki_preferences`, `wiki_matching`) saved by backend post-turn, fetched via `ApiService.getInsights()`, rendered in the Private Profile tab of `ProfileScreen`.

- [x] AI partial speech persists on barge-in interrupt
  - `_flushPendingAgentText()` is called before stopping playback on `interrupted` event, so partial AI text is committed to transcript before barge-in clears state.

- [x] Voice waveform is voice-reactive (not random)
  - PCM-RMS computed per audio chunk in `_recorderSink()`, fed into `_rawInputVolume` with attack/release smoothing, used directly by `_ComposerOutlinePainter`.

- [x] Mic button responds immediately on tap
  - `SessionState.connecting` added to `_voiceActive`; button shows amber fill and `more_horiz` icon during 2-4s connection setup.
