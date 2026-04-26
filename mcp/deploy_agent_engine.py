import os
import sys

import google.auth.transport.requests
import google.oauth2.id_token
import vertexai
from google.adk.agents import Agent
from google.adk.tools.mcp_tool.mcp_session_manager import SseServerParams
from google.adk.tools.mcp_tool.mcp_toolset import MCPToolset
from vertexai import agent_engines
from vertexai.preview.reasoning_engines import AdkApp

PROJECT_NUMBER = os.environ.get("PROJECT_NUMBER")
REGION = os.environ.get("REGION", "us-central1")
STAGING_BUCKET = os.environ.get("STAGING_BUCKET")
MCP_SERVER_URL = os.environ.get("MCP_SERVER_URL")

for value, name in [
    (PROJECT_NUMBER, "PROJECT_NUMBER"),
    (STAGING_BUCKET, "STAGING_BUCKET"),
    (MCP_SERVER_URL, "MCP_SERVER_URL"),
]:
    if not value:
        print(f"ERROR: {name} is not set.", file=sys.stderr)
        sys.exit(1)

# Mint a fresh identity token — tokens expire after 1 h, so we do this at
# deploy time rather than reusing the one from the local-test section.
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

app = AdkApp(agent=root_agent)

vertexai.init(
    project=PROJECT_NUMBER,
    location=REGION,
    staging_bucket=STAGING_BUCKET,
)

print("Deploying agent to Agent Engine (Vertex AI Reasoning Engines)...")
remote_app = agent_engines.create(
    display_name="HR Agent",
    agent_engine=app,
    requirements=[
        "google-adk==1.5.0",
        "google-genai==1.24.0",
        "pydantic==2.11.7",
    ],
)

print(f"\nAgent Engine resource name : {remote_app.resource_name}")
engine_id = remote_app.resource_name.split("/")[-1]
print(f"Reasoning Engine ID        : {engine_id}")

# Persist the ID so the demo script can read it without re-running this script.
id_file = "/tmp/reasoning_engine_id.txt"
with open(id_file, "w") as f:
    f.write(engine_id)
print(f"Engine ID saved to {id_file}")
