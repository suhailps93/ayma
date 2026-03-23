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

import asyncio
import json
import logging
import os
import uuid
from collections.abc import Callable
from contextlib import suppress
from pathlib import Path
from typing import Any, Literal

import backoff
import google.auth
import httpx
import vertexai
from fastapi import FastAPI, Header, HTTPException, Query, WebSocket, WebSocketException, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from google.cloud import logging as google_cloud_logging
from pydantic import BaseModel, Field
from supabase import Client, create_client
from websockets.exceptions import ConnectionClosedError

app = FastAPI()
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# Get the path to the frontend build directory
current_dir = Path(__file__).parent
frontend_build_dir = current_dir.parent.parent / "frontend" / "build"

# Mount assets if build directory exists
if frontend_build_dir.exists():
    app.mount(
        "/assets",
        StaticFiles(directory=str(frontend_build_dir / "assets")),
        name="assets",
    )
logging_client = google_cloud_logging.Client()
logger = logging_client.logger(__name__)
logging.basicConfig(level=logging.INFO)

NOMINATIM = "https://nominatim.openstreetmap.org"
NOMINATIM_UA = "AymaApp/1.0"

# Initialize default configuration
app.state.config = {
    "use_remote_agent": False,
    "remote_agent_engine_id": None,
    "project_id": None,
    "location": "us-central1",
    "local_agent_path": "..agent.root_agent",
    "agent_engine_object_path": "..agent_engine_app.agent_engine",
}


class WebSocketToQueueAdapter:
    """Adapter to convert WebSocket messages to an asyncio Queue for the agent engine."""

    def __init__(
        self,
        websocket: WebSocket,
        agent_engine: Any = None,
        remote_config: dict[str, Any] | None = None,
        authenticated_user_id: str | None = None,
    ):
        """Initialize the adapter.

        Args:
            websocket: The client websocket connection
            agent_engine: The agent engine instance with bidi_stream_query method (None if using remote)
            remote_config: Remote agent engine configuration (project_id, location, remote_agent_engine_id)
        """
        self.websocket = websocket
        self.agent_engine = agent_engine
        self.remote_config = remote_config
        self.authenticated_user_id = authenticated_user_id
        self.input_queue: asyncio.Queue[dict] = asyncio.Queue()
        self.first_message = True
        self.disconnected = False

    async def _safe_send_json(self, payload: dict[str, Any]) -> bool:
        """Send a websocket message unless the client has already disconnected."""
        if self.disconnected:
            return False

        try:
            await self.websocket.send_json(payload)
            return True
        except RuntimeError as e:
            self.disconnected = True
            logging.info(f"WebSocket closed while sending: {e}")
            return False

    def _transform_remote_agent_engine_response(self, response: dict) -> dict:
        """Transform remote Agent Engine bidiStreamOutput to ADK Event format for frontend."""
        # Check if this is a remote Agent Engine bidiStreamOutput
        bidi_output = response.get("bidiStreamOutput")
        if not bidi_output:
            # Not a remote agent engine response, return as-is
            return response

        # Transform to ADK Event format that frontend already handles
        # Just unwrap the bidiStreamOutput wrapper - the content is already in ADK Event format
        return bidi_output

    async def receive_from_client(self) -> None:
        """Listen for messages from the client and put them in the queue."""
        while True:
            try:
                # Use receive() instead of receive_json() to handle both text and binary data
                message = await self.websocket.receive()

                if message.get("type") == "websocket.disconnect":
                    self.disconnected = True
                    logging.info(
                        "Client disconnected: code=%s reason=%r",
                        message.get("code"),
                        message.get("reason", ""),
                    )
                    break

                # Handle different message types
                if "text" in message:
                    # Parse JSON text messages
                    data = json.loads(message["text"])

                    if isinstance(data, dict):
                        if self.authenticated_user_id:
                            data["user_id"] = self.authenticated_user_id
                            if isinstance(data.get("setup"), dict):
                                data["setup"]["user_id"] = self.authenticated_user_id

                        # Skip setup messages - they're for backend logging only, not valid LiveRequest format
                        if "setup" in data:
                            # Log setup information
                            logger.log_struct(
                                {**data["setup"], "type": "setup"}, severity="INFO"
                            )
                            logging.info(
                                "Received setup message (not forwarding to agent)"
                            )
                            continue

                        # Frontend handles message format for both modes
                        await self.input_queue.put(data)
                    else:
                        logging.warning(
                            f"Received unexpected JSON structure from client: {data}"
                        )

                elif "bytes" in message:
                    # Handle binary data
                    # Convert binary to appropriate format for agent engine
                    await self.input_queue.put({"binary_data": message["bytes"]})

                else:
                    logging.warning(
                        f"Received unexpected message type from client: {message}"
                    )

            except ConnectionClosedError as e:
                self.disconnected = True
                logging.warning(f"Client closed connection: {e}")
                break
            except json.JSONDecodeError as e:
                logging.error(f"Error parsing JSON from client: {e}")
                break
            except Exception as e:
                self.disconnected = True
                logging.error(f"Error receiving from client: {e!s}")
                break

    async def run_agent_engine(self) -> None:
        """Run the agent engine with the input queue."""
        try:
            if self.agent_engine is not None:
                # Local agent engine mode
                # Give the agent engine a moment to initialize before sending setupComplete
                await asyncio.sleep(1)

                # Send setupComplete after initialization delay
                setup_complete_response: dict = {"setupComplete": {}}
                if not await self._safe_send_json(setup_complete_response):
                    return

                async for response in self.agent_engine.bidi_stream_query(
                    self.input_queue
                ):
                    # Send responses from agent engine to the websocket client
                    if response is not None:
                        if not await self._safe_send_json(response):
                            return

                        # Check for error responses
                        if isinstance(response, dict) and "error" in response:
                            logging.error(f"Agent engine error: {response['error']}")
                            break
            else:
                # Remote agent engine mode
                # Don't send setupComplete until remote connection is established
                assert self.remote_config is not None, (
                    "remote_config must be set for remote mode"
                )
                await self.run_remote_agent_engine(
                    project_id=self.remote_config["project_id"],
                    location=self.remote_config["location"],
                    remote_agent_engine_id=self.remote_config["remote_agent_engine_id"],
                )
        except Exception as e:
            logging.error(f"Error in agent engine: {e}")
            await self._safe_send_json({"error": str(e)})

    async def run_remote_agent_engine(
        self, project_id: str, location: str, remote_agent_engine_id: str
    ) -> None:
        """Run the remote agent engine connection."""
        client = vertexai.Client(
            project=project_id,
            location=location,
        )

        async with client.aio.live.agent_engines.connect(
            agent_engine=remote_agent_engine_id,
            config={"class_method": "bidi_stream_query"},
        ) as session:
            # Send setupComplete only after remote connection is established
            logging.info("Remote agent engine connection established")
            setup_complete_response: dict = {"setupComplete": {}}
            if not await self._safe_send_json(setup_complete_response):
                return

            # Create task to forward messages from queue to remote session
            async def forward_to_remote() -> None:
                while True:
                    try:
                        message = await self.input_queue.get()
                        await session.send(message)
                    except Exception as e:
                        logging.error(f"Error forwarding to remote: {e}")
                        break

            # Create task to receive from remote and send to websocket
            async def receive_from_remote() -> None:
                while True:
                    try:
                        response = await session.receive()
                        if response is not None:
                            # Transform remote Agent Engine bidiStreamOutput format to frontend format
                            transformed = self._transform_remote_agent_engine_response(
                                response
                            )
                            if transformed:
                                if not await self._safe_send_json(transformed):
                                    break

                            # Check for error responses
                            if isinstance(response, dict) and "error" in response:
                                logging.error(
                                    f"Remote agent engine error: {response['error']}"
                                )
                                break
                    except Exception as e:
                        logging.error(f"Error receiving from remote: {e}")
                        break

            await asyncio.gather(
                forward_to_remote(),
                receive_from_remote(),
            )


def _dynamic_import(path: str) -> Any:
    """Dynamically import an object from a given path.

    Args:
        path: Python import path (e.g., '..agent.root_agent')

    Returns:
        The imported object
    """
    import importlib

    module_path, object_name = path.rsplit(".", 1)
    module = importlib.import_module(module_path, package=__package__)
    return getattr(module, object_name)


def get_connect_and_run_callable(
    websocket: WebSocket, config: dict[str, Any]
) -> Callable:
    """Create a callable that handles agent engine connection with retry logic.

    Args:
        websocket: The client websocket connection
        config: Configuration dict with agent engine settings

    Returns:
        Callable: An async function that establishes and manages the agent engine connection
    """

    async def on_backoff(details: backoff._typing.Details) -> None:
        await websocket.send_json(
            {
                "status": f"Model connection error, retrying in {details['wait']} seconds..."
            }
        )

    @backoff.on_exception(
        backoff.expo, ConnectionClosedError, max_tries=10, on_backoff=on_backoff
    )
    async def connect_and_run() -> None:
        authenticated_user_id = getattr(websocket.state, "authenticated_user_id", None)
        if config["use_remote_agent"]:
            # Remote agent engine mode
            logging.info(
                f"Connecting to remote agent engine: {config['remote_agent_engine_id']}"
            )
            remote_config = {
                "project_id": config["project_id"],
                "location": config["location"],
                "remote_agent_engine_id": config["remote_agent_engine_id"],
            }
            adapter = WebSocketToQueueAdapter(
                websocket,
                agent_engine=None,
                remote_config=remote_config,
                authenticated_user_id=authenticated_user_id,
            )
        else:
            # Local agent engine mode
            # Dynamically import the pre-configured agent_engine object
            agent_engine = _dynamic_import(config["agent_engine_object_path"])
            logging.info(
                f"Starting local agent engine with object: {type(agent_engine).__name__}"
            )

            adapter = WebSocketToQueueAdapter(
                websocket,
                agent_engine,
                authenticated_user_id=authenticated_user_id,
            )

        logging.info("Starting bidirectional communication with agent engine")
        receive_task = asyncio.create_task(adapter.receive_from_client())
        engine_task = asyncio.create_task(adapter.run_agent_engine())

        done, pending = await asyncio.wait(
            {receive_task, engine_task},
            return_when=asyncio.FIRST_COMPLETED,
        )

        for task in pending:
            task.cancel()

        for task in pending:
            with suppress(asyncio.CancelledError):
                await task

        for task in done:
            task.result()

    return connect_and_run


@app.websocket("/ws")
async def websocket_endpoint(
    websocket: WebSocket,
    token: str | None = Query(default=None),
) -> None:
    """Handle new websocket connections."""
    if not token:
        raise WebSocketException(
            code=status.WS_1008_POLICY_VIOLATION,
            reason="Missing auth token",
        )

    user_id = _get_current_user_id_from_token(token)
    await websocket.accept()
    connect_and_run = get_connect_and_run_callable(websocket, app.state.config)
    websocket.state.authenticated_user_id = user_id
    await connect_and_run()


class Feedback(BaseModel):
    """Represents feedback for a conversation."""

    score: int | float
    text: str | None = ""
    log_type: Literal["feedback"] = "feedback"
    user_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    session_id: str = Field(default_factory=lambda: str(uuid.uuid4()))


@app.post("/feedback")
def collect_feedback(feedback: Feedback) -> dict[str, str]:
    """Collect and log feedback.

    Args:
        feedback: The feedback data to log

    Returns:
        Success message
    """
    logger.log_struct(feedback.model_dump(), severity="INFO")
    return {"status": "success"}


class OnboardingPayload(BaseModel):
    display_name: str
    age: int
    gender: str
    location_region: str
    matching_prefs: dict[str, Any]


class ProfileUpdatePayload(BaseModel):
    profile_public: str
    profile_private: str


class LoginPayload(BaseModel):
    email: str
    password: str


class SignupPayload(BaseModel):
    email: str
    password: str


class RefreshPayload(BaseModel):
    refresh_token: str


def _get_supabase() -> Client:
    return create_client(
        os.environ["SUPABASE_URL"],
        os.environ["SUPABASE_SERVICE_ROLE_KEY"],
    )


def _get_supabase_auth_api_key() -> str:
    return os.environ.get("SUPABASE_ANON_KEY") or os.environ["SUPABASE_SERVICE_ROLE_KEY"]


def _supabase_auth_headers(access_token: str | None = None) -> dict[str, str]:
    headers = {
        "apikey": _get_supabase_auth_api_key(),
        "Content-Type": "application/json",
    }
    if access_token:
        headers["Authorization"] = f"Bearer {access_token}"
    return headers


def _format_auth_response(payload: dict[str, Any]) -> dict[str, Any]:
    user = payload.get("user")
    session = payload.get("session")
    if session is None and payload.get("access_token"):
        session = payload
    if user is None and isinstance(session, dict):
        user = session.get("user")

    formatted_user = None
    if isinstance(user, dict):
        formatted_user = {
            "id": user.get("id"),
            "email": user.get("email"),
        }

    formatted_session = None
    if isinstance(session, dict) and session.get("access_token"):
        formatted_session = {
            "access_token": session.get("access_token"),
            "refresh_token": session.get("refresh_token"),
            "expires_at": session.get("expires_at"),
            "token_type": session.get("token_type"),
            "user": formatted_user,
        }

    return {
        "user": formatted_user,
        "session": formatted_session,
        "requires_email_confirmation": formatted_session is None,
    }


def _supabase_auth_post(
    path: str,
    payload: dict[str, Any],
    *,
    params: dict[str, str] | None = None,
    access_token: str | None = None,
) -> dict[str, Any]:
    response = httpx.post(
        f"{os.environ['SUPABASE_URL']}/auth/v1{path}",
        params=params,
        headers=_supabase_auth_headers(access_token),
        json=payload,
        timeout=10.0,
    )
    if response.status_code >= 400:
        detail = response.text
        try:
            detail = response.json().get("msg") or response.json().get("message") or detail
        except Exception:
            pass
        raise HTTPException(status_code=response.status_code, detail=detail)
    return response.json() if response.content else {}


def _supabase_auth_get_user(token: str) -> dict[str, Any]:
    response = httpx.get(
        f"{os.environ['SUPABASE_URL']}/auth/v1/user",
        headers=_supabase_auth_headers(token),
        timeout=10.0,
    )
    if response.status_code >= 400:
        raise HTTPException(status_code=401, detail="Invalid bearer token")
    return response.json()


def _extract_bearer_token(authorization: str | None) -> str:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token")
    return authorization.removeprefix("Bearer ").strip()


def _get_current_user_id_from_token(token: str) -> str:
    user = _supabase_auth_get_user(token)
    user_id = user.get("id")
    if not user_id:
        raise HTTPException(status_code=401, detail="Invalid bearer token")
    return user_id


def _get_current_user_id(authorization: str | None) -> str:
    token = _extract_bearer_token(authorization)
    return _get_current_user_id_from_token(token)


async def _nominatim_get(path: str, params: dict[str, Any]) -> Any:
    async with httpx.AsyncClient(timeout=5.0) as client:
        response = await client.get(
            f"{NOMINATIM}{path}",
            params=params,
            headers={"User-Agent": NOMINATIM_UA},
        )
        response.raise_for_status()
        return response.json()


@app.post("/api/auth/login")
def login(payload: LoginPayload) -> dict[str, Any]:
    auth_response = _supabase_auth_post(
        "/token",
        {"email": payload.email, "password": payload.password},
        params={"grant_type": "password"},
    )
    return _format_auth_response(auth_response)


@app.post("/api/auth/signup")
def signup(payload: SignupPayload) -> dict[str, Any]:
    auth_response = _supabase_auth_post(
        "/signup",
        {"email": payload.email, "password": payload.password},
    )
    return _format_auth_response(auth_response)


@app.post("/api/auth/refresh")
def refresh_auth(payload: RefreshPayload) -> dict[str, Any]:
    auth_response = _supabase_auth_post(
        "/token",
        {"refresh_token": payload.refresh_token},
        params={"grant_type": "refresh_token"},
    )
    return _format_auth_response(auth_response)


@app.get("/api/auth/session")
def get_auth_session(authorization: str | None = Header(default=None)) -> dict[str, Any]:
    token = _extract_bearer_token(authorization)
    user = _supabase_auth_get_user(token)
    return {"user": {"id": user.get("id"), "email": user.get("email")}}


@app.post("/api/auth/logout")
def logout(authorization: str | None = Header(default=None)) -> dict[str, str]:
    token = _extract_bearer_token(authorization)
    httpx.post(
        f"{os.environ['SUPABASE_URL']}/auth/v1/logout",
        headers=_supabase_auth_headers(token),
        timeout=10.0,
    )
    return {"status": "ok"}


@app.get("/api/onboarding-status")
def get_onboarding_status(authorization: str | None = Header(default=None)) -> dict[str, bool]:
    user_id = _get_current_user_id(authorization)
    supabase = _get_supabase()
    result = (
        supabase.table("user_profiles")
        .select("onboarding_complete")
        .eq("id", user_id)
        .single()
        .execute()
    )
    return {"onboarding_complete": bool((result.data or {}).get("onboarding_complete"))}


@app.post("/api/onboarding")
def save_onboarding(
    payload: OnboardingPayload,
    authorization: str | None = Header(default=None),
) -> dict[str, str]:
    user_id = _get_current_user_id(authorization)
    supabase = _get_supabase()
    supabase.table("user_profiles").upsert(
        {
            "id": user_id,
            "display_name": payload.display_name.strip(),
            "age": payload.age,
            "gender": payload.gender,
            "location_region": payload.location_region.strip(),
            "matching_prefs": payload.matching_prefs,
            "onboarding_complete": True,
        }
    ).execute()
    return {"status": "ok"}


@app.get("/api/profile")
def get_profile(authorization: str | None = Header(default=None)) -> dict[str, Any]:
    user_id = _get_current_user_id(authorization)
    supabase = _get_supabase()
    result = (
        supabase.table("user_profile_safe")
        .select(
            "id, display_name, profile_public, profile_private, "
            "profile_public_locked, agent_name, voice_preference, matching_prefs, "
            "age, gender, location_region, community_profile, onboarding_complete"
        )
        .eq("id", user_id)
        .single()
        .execute()
    )
    return result.data or {}


@app.post("/api/profile")
def update_profile(
    payload: ProfileUpdatePayload,
    authorization: str | None = Header(default=None),
) -> dict[str, str]:
    user_id = _get_current_user_id(authorization)
    supabase = _get_supabase()
    supabase.table("user_profiles").update(
        {
            "profile_public": payload.profile_public.strip(),
            "profile_private": payload.profile_private.strip(),
            "profile_public_locked": True,
        }
    ).eq("id", user_id).execute()
    return {"status": "ok"}


@app.get("/api/matches")
def get_matches(authorization: str | None = Header(default=None)) -> list[dict[str, Any]]:
    user_id = _get_current_user_id(authorization)
    supabase = _get_supabase()
    result = (
        supabase.table("matches")
        .select("*")
        .or_(f"user_a.eq.{user_id},user_b.eq.{user_id}")
        .order("score", desc=True)
        .limit(50)
        .execute()
    )
    return result.data or []


@app.get("/api/location/search")
async def search_location(q: str = Query(min_length=1)) -> list[dict[str, str]]:
    data = await _nominatim_get(
        "/search",
        {"q": q, "format": "json", "limit": 5, "addressdetails": 1},
    )
    results = []
    for item in data:
        address = item.get("address", {})
        locality = (
            address.get("city")
            or address.get("town")
            or address.get("village")
            or address.get("county")
            or address.get("state")
            or ""
        )
        short_name = f"{locality}, {address['country']}" if address.get("country") else locality
        results.append(
            {
                "display_name": item.get("display_name", ""),
                "short_name": short_name or item.get("display_name", ""),
                "lat": str(item.get("lat", "")),
                "lon": str(item.get("lon", "")),
            }
        )
    return results


@app.get("/api/location/reverse")
async def reverse_location(lat: float, lon: float) -> dict[str, str]:
    data = await _nominatim_get(
        "/reverse",
        {"lat": lat, "lon": lon, "format": "json"},
    )
    address = data.get("address", {})
    locality = (
        address.get("city")
        or address.get("town")
        or address.get("village")
        or address.get("county")
        or address.get("state")
        or ""
    )
    short_name = f"{locality}, {address['country']}" if address.get("country") else locality
    return {"location": short_name}


@app.get("/")
async def serve_frontend_root() -> FileResponse:
    """Serve the frontend index.html at the root path."""
    index_file = frontend_build_dir / "index.html"
    if index_file.exists():
        return FileResponse(str(index_file))
    raise HTTPException(
        status_code=404,
        detail="Frontend not built. Run 'npm run build' in the frontend directory.",
    )


@app.get("/{full_path:path}")
async def serve_frontend_spa(full_path: str) -> FileResponse:
    """Catch-all route to serve the frontend for SPA routing.

    This ensures that client-side routes are handled by the React app.
    Excludes API routes (ws, feedback) and assets.
    """
    # Don't intercept API routes
    if full_path.startswith(("ws", "feedback", "assets", "api")):
        raise HTTPException(status_code=404, detail="Not found")

    # Serve index.html for all other routes (SPA routing)
    index_file = frontend_build_dir / "index.html"
    if index_file.exists():
        return FileResponse(str(index_file))
    raise HTTPException(
        status_code=404,
        detail="Frontend not built. Run 'npm run build' in the frontend directory.",
    )


# Main execution
if __name__ == "__main__":
    import argparse

    import uvicorn

    parser = argparse.ArgumentParser(description="Agent Engine Proxy Server")
    parser.add_argument(
        "--mode",
        choices=["local", "remote"],
        default="local",
        help="Agent engine mode: 'local' for local agent or 'remote' for deployed agent engine",
    )
    parser.add_argument(
        "--remote-id",
        type=str,
        help="Remote agent engine ID (required when mode=remote)",
    )
    parser.add_argument(
        "--project-id", type=str, help="GCP project ID (required when mode=remote)"
    )
    parser.add_argument(
        "--location",
        type=str,
        default="us-central1",
        help="GCP location (default: us-central1)",
    )
    parser.add_argument(
        "--local-agent",
        type=str,
        default="..agent.root_agent",
        help="Python path to local agent callable (e.g., 'app.agent.root_agent')",
    )
    parser.add_argument(
        "--agent-engine-object",
        type=str,
        default="..agent_engine_app.agent_engine",
        help="Python path to agent engine object instance",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=8000,
        help="Port to run the server on (default: 8000)",
    )
    parser.add_argument(
        "--host",
        type=str,
        default="localhost",
        help="Host to run the server on (default: localhost)",
    )

    args = parser.parse_args()

    # Initialize configuration
    config: dict[str, Any] = {
        "use_remote_agent": False,
        "remote_agent_engine_id": None,
        "project_id": None,
        "location": "us-central1",
        "local_agent_path": args.local_agent,
        "agent_engine_object_path": args.agent_engine_object,
    }

    if args.mode == "remote":
        config["use_remote_agent"] = True

        # Try to load from deployment_metadata.json if remote-id not provided
        if not args.remote_id:
            deployment_metadata_path = (
                Path(__file__).parent.parent.parent / "deployment_metadata.json"
            )
            if deployment_metadata_path.exists():
                with open(deployment_metadata_path) as f:
                    metadata = json.load(f)
                    config["remote_agent_engine_id"] = metadata.get(
                        "remote_agent_engine_id"
                    )
                    if not config["remote_agent_engine_id"]:
                        parser.error(
                            "No remote_agent_engine_id found in deployment_metadata.json"
                        )
                    print("Loaded remote agent engine ID from deployment_metadata.json")
            else:
                parser.error(
                    "--remote-id is required when deployment_metadata.json is not found"
                )
        else:
            config["remote_agent_engine_id"] = args.remote_id

        # Extract project ID from remote agent engine ID if not provided
        if not args.project_id:
            # Format: projects/PROJECT_ID/locations/LOCATION/reasoningEngines/ENGINE_ID
            import re

            remote_id: str = config["remote_agent_engine_id"]
            match = re.match(
                r"projects/([^/]+)/locations/([^/]+)/reasoningEngines/",
                remote_id,
            )
            if match:
                config["project_id"] = match.group(1)
                extracted_location = match.group(2)
                config["location"] = (
                    args.location
                    if args.location != "us-central1"
                    else extracted_location
                )
                print("Extracted project ID and location from remote agent engine ID")
            else:
                # Fall back to google.auth.default()
                try:
                    _, config["project_id"] = google.auth.default()
                    config["location"] = args.location
                    print(
                        f"Using default project ID from google.auth: {config['project_id']}"
                    )
                except Exception as e:
                    parser.error(f"Could not determine project ID: {e}")
        else:
            config["project_id"] = args.project_id
            config["location"] = args.location

        print("Starting server in REMOTE mode:")
        print(f"  Remote Agent Engine ID: {config['remote_agent_engine_id']}")
        print(f"  Project ID: {config['project_id']}")
        print(f"  Location: {config['location']}")
    else:
        print("Starting server in LOCAL mode")
        print(f"  Using agent: {config['local_agent_path']}")
        print(f"  Using agent engine object: {config['agent_engine_object_path']}")

    # Store configuration in app state
    app.state.config = config

    uvicorn.run(app, host=args.host, port=args.port)
