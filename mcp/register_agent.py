import os
import subprocess
import sys

import requests

PROJECT_ID = os.environ.get("PROJECT_ID")
PROJECT_NUMBER = os.environ.get("PROJECT_NUMBER")
REGION = os.environ.get("REGION", "us-central1")
GEMINI_ENTERPRISE_ENGINE_ID = os.environ.get("GEMINI_ENTERPRISE_ENGINE_ID")
OAUTH_CLIENT_ID = os.environ.get("OAUTH_CLIENT_ID")
OAUTH_CLIENT_SECRET = os.environ.get("OAUTH_CLIENT_SECRET")
REASONING_ENGINE_ID = os.environ.get("REASONING_ENGINE_ID")
AUTH_ID = os.environ.get("AUTH_ID", "customhr9893")

for value, name in [
    (PROJECT_ID, "PROJECT_ID"),
    (PROJECT_NUMBER, "PROJECT_NUMBER"),
    (GEMINI_ENTERPRISE_ENGINE_ID, "GEMINI_ENTERPRISE_ENGINE_ID"),
    (OAUTH_CLIENT_ID, "OAUTH_CLIENT_ID"),
    (OAUTH_CLIENT_SECRET, "OAUTH_CLIENT_SECRET"),
    (REASONING_ENGINE_ID, "REASONING_ENGINE_ID"),
]:
    if not value:
        print(f"ERROR: {name} is not set.", file=sys.stderr)
        sys.exit(1)

access_token = subprocess.check_output(
    ["gcloud", "auth", "print-access-token"], text=True
).strip()

http_headers = {
    "Authorization": f"Bearer {access_token}",
    "Content-Type": "application/json",
    "X-Goog-User-Project": PROJECT_ID,
}

BASE = "https://discoveryengine.googleapis.com/v1alpha"

# ── Call 1: Authorization resource ───────────────────────────────────────────
# Gemini Enterprise uses this to obtain OAuth tokens on behalf of end-users.
print("Step 1 — Creating Authorization resource...")
auth_url = (
    f"{BASE}/projects/{PROJECT_ID}/locations/global/authorizations"
    f"?authorizationId={AUTH_ID}"
)
auth_body = {
    "name": f"projects/{PROJECT_ID}/locations/global/authorizations/{AUTH_ID}",
    "serverSideOauth2": {
        "clientId": OAUTH_CLIENT_ID,
        "clientSecret": OAUTH_CLIENT_SECRET,
        "authorizationUri": (
            f"https://accounts.google.com/o/oauth2/v2/auth"
            f"?client_id={OAUTH_CLIENT_ID}"
            f"&scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcloud-platform"
            f"&include_granted_scopes=true&response_type=code"
            f"&access_type=offline&prompt=consent"
        ),
        "tokenUri": "https://oauth2.googleapis.com/token",
    },
}
resp = requests.post(auth_url, headers=http_headers, json=auth_body)
print(f"  HTTP {resp.status_code}")
print(f"  {resp.text[:300]}\n")

# ── Call 2: Agent record ─────────────────────────────────────────────────────
# Links the Reasoning Engine endpoint to the Gemini Enterprise assistant.
print("Step 2 — Registering agent with Gemini Enterprise...")
agent_url = (
    f"{BASE}/projects/{PROJECT_ID}/locations/global"
    f"/collections/default_collection"
    f"/engines/{GEMINI_ENTERPRISE_ENGINE_ID}"
    f"/assistants/default_assistant/agents"
)
agent_body = {
    "displayName": "HR Agent",
    "description": "Helps employees apply for leave via natural language.",
    "adk_agent_definition": {
        "tool_settings": {
            "tool_description": "Helps employees apply for leave via natural language."
        },
        "provisioned_reasoning_engine": {
            "reasoning_engine": (
                f"projects/{PROJECT_NUMBER}/locations/{REGION}"
                f"/reasoningEngines/{REASONING_ENGINE_ID}"
            )
        },
        "authorizations": [
            f"projects/{PROJECT_NUMBER}/locations/global/authorizations/{AUTH_ID}"
        ],
    },
}
resp = requests.post(agent_url, headers=http_headers, json=agent_body)
print(f"  HTTP {resp.status_code}")
print(f"  {resp.text[:500]}\n")

if resp.status_code in (200, 201):
    print("Agent registered successfully.")
    print("Open Gemini Enterprise — the HR Agent is ready to chat.")
else:
    print("Registration failed — check the response above and verify your credentials.")
    sys.exit(1)
