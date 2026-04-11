import os

from google import genai as google_genai


def use_vertex() -> bool:
    return os.environ.get("GOOGLE_GENAI_USE_VERTEXAI", "").lower() in {"1", "true", "yes"}


def create_genai_client() -> google_genai.Client:
    if use_vertex():
        return google_genai.Client(
            vertexai=True,
            project=os.environ["GOOGLE_CLOUD_PROJECT"],
            location=os.environ["GOOGLE_CLOUD_LOCATION"],
        )
    return google_genai.Client(api_key=os.environ["GOOGLE_API_KEY"])
