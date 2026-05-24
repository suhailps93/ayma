# E2E Critical TODO

- [ ] Chat auto-scroll opens at latest message
  - Status: in progress
  - Done criteria: tested on device with existing long transcript; opens at bottom consistently.

- [ ] Voice does not auto-start on chat open
  - Status: in progress
  - Done criteria: tested on device; chat opens disconnected/offline until mic tap.

- [ ] "Your Story" page population works end-to-end
  - Status: in progress
  - Done criteria: verified that skills/memory fields are saved, fetched, and rendered in UI with real profile data.

- [ ] AI partial speech persists on barge-in interrupt
  - Status: implemented, pending test
  - Done criteria: while AI is speaking, user interrupts; existing AI partial text remains visible in transcript without duplicate bubble on turnComplete.
