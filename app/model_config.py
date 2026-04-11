import os


LIVE_MODEL = os.environ.get("LIVE_MODEL", "gemini-3.1-flash-live-preview")
TEXT_MODEL = os.environ.get("TEXT_MODEL", "gemini-3-flash-preview")
FAST_MODEL = os.environ.get("FAST_MODEL", TEXT_MODEL)
EMBEDDING_MODEL = os.environ.get("EMBEDDING_MODEL", "gemini-embedding-2-preview")
