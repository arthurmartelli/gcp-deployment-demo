import os
import sys

import google.auth.transport.requests
import google.oauth2.id_token
from google.adk.agents import Agent
from google.adk.tools.mcp_tool.mcp_session_manager import SseServerParams
from google.adk.tools.mcp_tool.mcp_toolset import MCPToolset
from google.genai import types
from vertexai.preview import reasoning_engines

MCP_SERVER_URL = os.environ.get("MCP_SERVER_URL")
if not MCP_SERVER_URL:
    print("ERROR: MCP_SERVER_URL is not set.", file=sys.stderr)
    sys.exit(1)

# Exchange service-account credentials for a short-lived Bearer token
# accepted by the --no-allow-unauthenticated Cloud Run service.
auth_req = google.auth.transport.requests.Request()
id_token = google.oauth2.id_token.fetch_id_token(auth_req, MCP_SERVER_URL)
headers = {"Authorization": f"Bearer {id_token}"}

AGENT_PROMPT = """
You are an HR assistant with tools to apply employee leave.
When a user wants to apply for leave, collect their employee ID, start date,
and end date, then call apply_leave. Confirm the action once done.
"""

tools = MCPToolset(
    connection_params=SseServerParams(url=MCP_SERVER_URL, headers=headers),
)

root_agent = Agent(
    model="gemini-2.5-pro",
    name="hr_agent",
    instruction=AGENT_PROMPT,
    tools=[tools],
)

# AdkApp exposes the same stream_query API locally as Agent Engine does in production.
# This lets us validate the full tool-calling loop before paying for a remote deployment.
app = reasoning_engines.AdkApp(
    agent=root_agent,
    enable_tracing=True,
)

session = app.create_session(user_id="demo_user")
print(f"Session created: {session.id}\n")

QUERY = "My employee ID is 42. I need leave from 2025-08-01 to 2025-08-05."
print(f"User: {QUERY}\n")

contents = types.Content(role="user", parts=[types.Part.from_text(text=QUERY)])

for event in app.stream_query(
    user_id="demo_user",
    session_id=session.id,
    message=contents.model_dump(),
):
    print(event)
