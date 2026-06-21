from google import genai
from google.genai.types import CreateAuthTokenConfig, LiveConnectConstraints

setup_backend = {
    "system_instruction": {"parts": [{"text": "Hello world"}]}
}

c = CreateAuthTokenConfig(
    uses=1,
    live_connect_constraints=LiveConnectConstraints(
        config={
            "system_instruction": setup_backend["system_instruction"]
        }
    )
)

print(c.model_dump(exclude_none=True))
