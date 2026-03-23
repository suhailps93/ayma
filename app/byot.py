"""
BYOT — Bring Your Own Token

Users can supply their own LLM API keys. We encrypt them with Fernet (AES-256)
before storing in user_tokens. Keys never leave the server unencrypted.

The encryption key (AYMA_FERNET_KEY) must be set in the environment.
Generate one with: python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
"""
import os
from cryptography.fernet import Fernet
from supabase import create_client


def _fernet() -> Fernet:
    key = os.environ.get("AYMA_FERNET_KEY")
    if not key:
        raise ValueError("AYMA_FERNET_KEY not set in environment")
    return Fernet(key.encode())


def encrypt_key(plaintext: str) -> str:
    return _fernet().encrypt(plaintext.encode()).decode()


def decrypt_key(ciphertext: str) -> str:
    return _fernet().decrypt(ciphertext.encode()).decode()


def store_user_token(user_id: str, provider: str, api_key: str, label: str = "") -> None:
    """Encrypt and store a user's API key. Replaces existing key for the same provider."""
    encrypted = encrypt_key(api_key)
    supabase = create_client(
        os.environ["SUPABASE_URL"],
        os.environ["SUPABASE_SERVICE_ROLE_KEY"],
    )
    supabase.table("user_tokens").upsert({
        "user_id": user_id,
        "provider": provider,
        "encrypted_key": encrypted,
        "label": label,
    }, on_conflict="user_id,provider").execute()


def get_user_token(user_id: str, provider: str) -> str | None:
    """Retrieve and decrypt a user's API key. Returns None if not set."""
    supabase = create_client(
        os.environ["SUPABASE_URL"],
        os.environ["SUPABASE_SERVICE_ROLE_KEY"],
    )
    result = supabase.table("user_tokens").select("encrypted_key").eq(
        "user_id", user_id
    ).eq("provider", provider).execute()

    if not result.data:
        return None
    return decrypt_key(result.data[0]["encrypted_key"])
