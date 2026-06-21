// Centralized configuration constants for the audio recording, VAD processing,
// connection handling, and playback orchestration.
class AudioConfig {
  AudioConfig._();

  // ── Hardware & Encoding Parameters ──────────────────────────────────────────
  /// Sampling rate of the raw input PCM16 microphone stream (Hz)
  static const int inputSampleRate = 16000;

  /// Default sampling rate for output audio stream playback (Hz)
  static const int outputSampleRate = 24000;

  /// Number of channels for voice audio streams (1 for Mono)
  static const int channelCount = 1;

  /// Sample size in bytes per channel sample (16-bit PCM = 2 bytes)
  static const int sampleSizeInBytes = 2;

  /// Target packet frame duration (ms)
  static const int packetDurationMs = 40;

  /// Fixed frame buffer byte size.
  /// Computed as: sampleRate * channels * sampleSizeInBytes * (packetDurationMs / 1000)
  /// e.g., 16000 * 1 * 2 * 0.040 = 1280 bytes
  static const int frameSize = 1280;

  /// Subscription interval duration for mobile native sound recorder (ms)
  static const int subscriptionDurationMs = 80;

  /// Maximum absolute amplitude value of a 16-bit signed linear PCM sample
  static const double maxPcmValue = 32768.0;

  // ── Voice Activity Detection (VAD) Tuning ──────────────────────────────────
  /// Default RMS energy threshold below which speech is considered silence (used in detector)
  static const double defaultRmsThreshold = 0.015;

  /// Active RMS energy threshold used by Audio Service orchestration
  static const double activeRmsThreshold = 0.018;

  /// Minimum Zero-Crossing Rate threshold to identify human vocal characteristics
  static const double zcrMin = 0.03;

  /// Maximum Zero-Crossing Rate threshold to filter out high-frequency transient noise/sibilance
  static const double zcrMax = 0.35;

  /// Hangover duration to keep stream active during brief mid-sentence speech pauses (ms)
  static const int hangoverDurationMs = 800;

  /// Duration of pre-buffer window to capture leading consonants and avoid clipping (ms)
  static const int preBufferDurationMs = 300;

  // ── Session Orchestration & Timers ─────────────────────────────────────────
  /// User talking visual status retention window (ms)
  static const int userTalkHoldoffMs = 1200;

  /// Max log/UI lines retained in screen transcripts
  static const int maxTranscriptLines = 180;

  /// Max turns stored in context history list
  static const int maxHistoryLength = 60;

  /// Pause delay before disconnecting on goodbye wake words (ms)
  static const int goodbyeDelayMs = 400;

  /// Debounce time before persisting transcript to local preferences storage (ms)
  static const int persistDebounceMs = 900;

  /// Time interval required to prevent duplicate transcript line updates (seconds)
  static const int duplicatePreventSeconds = 3;

  /// Max UI refresh rate/throttling duration for active visual meters (ms)
  static const int uiMeterUpdateIntervalMs = 33;

  /// Throttling interval for visual amplitude level indicators (ms)
  static const int uiMeterThrottledIntervalMs = 260;

  // ── Wake Word & Local Speech Engines ───────────────────────────────────────
  /// Max duration to capture and listen for the local wake-word before stopping (seconds)
  static const int wakeWordListenForSeconds = 8;

  /// Pause duration to wait before resuming wake-word engine analysis (seconds)
  static const int wakeWordPauseForSeconds = 3;

  /// Delay to wait before re-initializing wake-word analysis after a cycle (ms)
  static const int wakeWordDelayMs = 300;

  // ── Output Playback Tracking & Buffers ─────────────────────────────────────
  /// Bytes per millisecond for output playback tracking (24kHz Mono, 16-bit = 48.0 bytes/ms)
  static const double bytesPerMs24k = 48.0;

  /// Minimum playback decay hold window limit (ms)
  static const double minPlaybackDecayMs = 200.0;

  /// Maximum playback decay hold window limit (ms)
  static const double maxPlaybackDecayMs = 8000.0;

  /// Grace period added to the playback decay window (ms)
  static const int playbackDecayGraceMs = 250;

  /// Fallback output sample rate if mime type parsing fails (Hz)
  static const int fallbackOutputSampleRate = 24000;

  /// Fallback channel count if mime type parsing fails
  static const int fallbackChannelCount = 1;

  /// Output audio player stream buffer size (bytes)
  static const int playerBufferSize = 32768;

  /// Minimum decibels used to normalize volume indicator streams (dB)
  static const double minDecibels = -60.0;

  /// Range of decibels used to scale volume values to a 0.0-1.0 range (dB)
  static const double decibelRange = 60.0;

  // ── Network & Reconnection Loop ────────────────────────────────────────────
  /// Max attempts to automatically reconnect the WebSocket
  static const int maxReconnectAttempts = 5;

  /// Base multiplication factor for exponential backoff calculations (ms)
  static const int reconnectBackoffBaseMs = 500;

  /// Heartbeat ping interval configuration for IOWebSocketChannel (seconds)
  static const int websocketPingIntervalSeconds = 30;

  /// Connection establishment timeout duration (seconds)
  static const int connectionTimeoutSeconds = 12;

  /// General HTTP network request timeout limit (seconds)
  static const int httpTimeoutSeconds = 12;

  /// Deadline duration to complete retry operations (seconds)
  static const int retryDeadlineSeconds = 6;

  /// Interval to poll during a request retry cycle (ms)
  static const int retryPollIntervalMs = 120;

  /// Timeout limit for fetching provider bootstrap configs (seconds)
  static const int bootstrapTimeoutSeconds = 15;

  /// General HTTP request timeout for heavy query payloads (seconds)
  static const int httpImageQueryTimeoutSeconds = 30;

  /// Visual volume EMA alpha smoothing factor when increasing
  static const double volumeEmaAlphaAttack = 0.35;

  /// Visual volume EMA alpha smoothing factor when decaying
  static const double volumeEmaAlphaDecay = 0.15;

  /// Timeout to trigger fallback if OpenAI realtime output response takes too long (seconds)
  static const int openaiResponseFallbackSeconds = 10;
}
