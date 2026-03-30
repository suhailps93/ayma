# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
import logging
import os
from typing import Any

import vertexai
from dotenv import load_dotenv
from google.adk.artifacts import GcsArtifactService, InMemoryArtifactService
from google.cloud import logging as google_cloud_logging
from vertexai.agent_engines.templates.adk import AdkApp
from vertexai.preview.reasoning_engines import AdkApp as PreviewAdkApp

from app.agent import app as default_adk_app
from app.agent import create_app
from app.app_utils.telemetry import setup_telemetry
from app.app_utils.typing import Feedback

# Load environment variables from .env file at runtime
load_dotenv()


class AgentEngineApp(AdkApp):
    def set_up(self) -> None:
        """Initialize the agent engine app with logging and telemetry."""
        vertexai.init()
        setup_telemetry()
        super().set_up()
        # super().set_up() (Vertex AI AdkApp) always sets GOOGLE_GENAI_USE_VERTEXAI=1.
        # We use AI Studio via GOOGLE_API_KEY, so reset it here before any LLM
        # connection is made (the ADK's _api_backend is a lazy cached_property).
        os.environ["GOOGLE_GENAI_USE_VERTEXAI"] = "0"
        logging.basicConfig(level=logging.INFO)
        logging_client = google_cloud_logging.Client()
        self.logger = logging_client.logger(__name__)
        if gemini_location:
            os.environ["GOOGLE_CLOUD_LOCATION"] = gemini_location

    def register_feedback(self, feedback: dict[str, Any]) -> None:
        """Collect and log feedback."""
        feedback_obj = Feedback.model_validate(feedback)
        self.logger.log_struct(feedback_obj.model_dump(), severity="INFO")

    def register_operations(self) -> dict[str, list[str]]:
        """Registers the operations of the Agent."""
        operations = super().register_operations()
        operations[""] = operations.get("", []) + ["register_feedback"]
        # Add bidi_stream_query for adk_live
        operations["bidi_stream"] = ["bidi_stream_query"]
        return operations


# Add bidi_stream_query support from preview AdkApp for adk_live
AgentEngineApp.bidi_stream_query = PreviewAdkApp.bidi_stream_query


gemini_location = os.environ.get("GOOGLE_CLOUD_LOCATION")
logs_bucket_name = os.environ.get("LOGS_BUCKET_NAME")
def _artifact_service_builder() -> GcsArtifactService | InMemoryArtifactService:
    return (
        GcsArtifactService(bucket_name=logs_bucket_name)
        if logs_bucket_name
        else InMemoryArtifactService()
    )


def get_agent_engine(user_id: str | None = None) -> AgentEngineApp:
    return AgentEngineApp(
        app=create_app(user_id),
        artifact_service_builder=_artifact_service_builder,
    )


agent_engine = AgentEngineApp(
    app=default_adk_app,
    artifact_service_builder=_artifact_service_builder,
)
