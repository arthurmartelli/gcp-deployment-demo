#!/usr/bin/env bash

source "$(dirname "$0")/demo.sh"

# Config — set or export these before running
PROJECT_ID="${PROJECT_ID?Please set PROJECT_ID (e.g. my-gcp-project)}"
PROJECT_NUMBER="${PROJECT_NUMBER?Please set PROJECT_NUMBER (numeric GCP project number)}"
REGION="${REGION:-us-central1}"
STAGING_BUCKET="${STAGING_BUCKET?Please set STAGING_BUCKET (e.g. gs://my-staging-bucket)}"
GEMINI_ENTERPRISE_ENGINE_ID="${GEMINI_ENTERPRISE_ENGINE_ID?Please set GEMINI_ENTERPRISE_ENGINE_ID}"
OAUTH_CLIENT_ID="${OAUTH_CLIENT_ID?Please set OAUTH_CLIENT_ID}"
OAUTH_CLIENT_SECRET="${OAUTH_CLIENT_SECRET?Please set OAUTH_CLIENT_SECRET}"

ASSETS_DIR="$(cd "$(dirname "$0")/assets" && pwd)"

DATASET_ID="bqds_hr_data"
TABLE_NAME="employee_leave"
REPO_NAME="mcp-server"
MCP_IMAGE_NAME="hr-tool-server"
IMAGE_TAG="latest"
IMAGE_PATH="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${MCP_IMAGE_NAME}:${IMAGE_TAG}"
SERVICE_NAME="hr-tool-server"
AUTH_ID="customhr9893"

# Populated at runtime — sections downstream read these
MCP_SERVER_URL=""
REASONING_ENGINE_ID=""
SECTION=""

# Make project identity available to every child process (Python scripts, etc.)
export PROJECT_ID PROJECT_NUMBER REGION

# =============================================================================
# SECTIONS
# =============================================================================

# --- Setup -------------------------------------------------------------------
section_setup() {
  demo_type "=== §$SECTION / 6  SETUP ==="
  demo_type "Goal: confirm identity, configure project, and enable all required GCP APIs."
  demo_type "First, verify which account is active in this shell"
  demo_invoke gcloud auth list

  demo_type "Pin gcloud to the target project for all subsequent commands"
  demo_invoke gcloud config set project "$PROJECT_ID"

  clear
  demo_type "Enable every API this demo will touch in one shot:"
  demo_type "  iam, bigquery, run, cloudbuild, artifactregistry, aiplatform, discoveryengine"
  demo_invoke gcloud services enable \
    iam.googleapis.com \
    bigquery.googleapis.com \
    run.googleapis.com \
    cloudbuild.googleapis.com \
    artifactregistry.googleapis.com \
    aiplatform.googleapis.com \
    discoveryengine.googleapis.com

  clear
  demo_type "All pre-written source files for this demo live in the assets/ directory"
  demo_invoke ls "$ASSETS_DIR"
  demo_type "We will read each file as we reach its section."
  demo_wait "APIs enabled — let's build."
}

# --- BigQuery ----------------------------------------------------------------
section_bigquery() {
  demo_type ""
  demo_type "=== §$SECTION / 6  BIGQUERY ==="
  demo_type "The MCP server needs a durable store for leave records."
  demo_type "BigQuery is serverless — no database to provision, patch, or scale."
  demo_type ""
  demo_type "Table schema:"
  demo_type "  employee_id      INTEGER   — identifies the employee"
  demo_type "  leave_start_date DATE      — first day of leave (YYYY-MM-DD)"
  demo_type "  leave_end_date   DATE      — last day of leave  (YYYY-MM-DD)"
  demo_wait "Create the dataset"

  demo_invoke bq mk --dataset "$PROJECT_NUMBER:$DATASET_ID"

  demo_type "Create the leave table with an inline schema definition"
  demo_invoke bq mk \
    --table \
    "$PROJECT_NUMBER:$DATASET_ID.$TABLE_NAME" \
    employee_id:INTEGER,leave_start_date:DATE,leave_end_date:DATE

  demo_type "Verify the schema was applied correctly"
  demo_invoke bq show --schema --format=prettyjson \
    "$PROJECT_NUMBER:$DATASET_ID.$TABLE_NAME"

  demo_wait "BigQuery backend ready. Next: package the MCP server."
}

# --- Artifact Registry + Cloud Build -----------------------------------------
section_build_and_push() {
  demo_type ""
  demo_type "=== §$SECTION / 6  ARTIFACT REGISTRY + CLOUD BUILD ==="
  demo_type "We need a container image before we can deploy to Cloud Run."
  demo_type "Let's read the three files that make up the MCP server."
  demo_wait "Start with the server code"

  demo_invoke cat "$ASSETS_DIR/mcp_server.py"
  demo_type "Key points:"
  demo_type "  @mcp.tool() turns a plain Python function into an MCP-callable tool"
  demo_type "  apply_leave() writes a row to BigQuery; any error surfaces as an exception"
  demo_type "  Starlette routes: /sse for the SSE stream, /messages/ for client posts"

  clear
  demo_invoke cat "$ASSETS_DIR/Dockerfile"
  demo_type "Python 3.10 slim base — installs deps, copies the server, starts uvicorn on 8080."

  demo_invoke cat "$ASSETS_DIR/requirements.txt"
  demo_type "FastMCP (via mcp[cli]), uvicorn, Starlette, and the BigQuery client is all it needs."

  clear
  demo_type "Create an Artifact Registry Docker repository to hold the server image"
  demo_type "Images will live under: $IMAGE_PATH"
  demo_invoke gcloud artifacts repositories create "$REPO_NAME" \
    --repository-format=docker \
    --location="$REGION" \
    --description="MCP server images for the HR demo"

  demo_type "gcloud builds submit does three things in one command:"
  demo_type "  1. Tars and uploads assets/ to Cloud Storage as the build context"
  demo_type "  2. Runs the Dockerfile inside a Cloud Build worker (not your machine)"
  demo_type "  3. Pushes the resulting image straight to Artifact Registry"
  demo_invoke gcloud builds submit "$ASSETS_DIR" \
    --tag="$IMAGE_PATH" \
    --project="$PROJECT_ID"

  demo_wait "Image is in Artifact Registry. Ready to deploy the MCP server."
}

# --- Cloud Run ---------------------------------------------------------------
section_cloud_run() {
  demo_type ""
  demo_type "=== §$SECTION / 6  MCP SERVER ON CLOUD RUN ==="
  demo_type "Cloud Run gives us a managed, auto-scaling HTTPS endpoint — no cluster to operate."
  demo_type ""
  demo_type "Flag choices explained:"
  demo_type "  --no-allow-unauthenticated   only callers presenting a GCP identity token are accepted"
  demo_type "                               the ADK agent mints one automatically at call time"
  demo_type "  --min-instances=1            keeps one warm instance to prevent SSE cold-start drops"
  demo_type "  --set-env-vars               injects BigQuery config without baking values into the image"
  demo_wait "Deploy the MCP server"

  demo_invoke gcloud run deploy "$SERVICE_NAME" \
    --image="$IMAGE_PATH" \
    --platform=managed \
    --region="$REGION" \
    --no-allow-unauthenticated \
    --set-env-vars="APP_HOST=0.0.0.0" \
    --set-env-vars="APP_PORT=8080" \
    --set-env-vars="GOOGLE_GENAI_USE_VERTEXAI=TRUE" \
    --set-env-vars="GOOGLE_CLOUD_LOCATION=$REGION" \
    --set-env-vars="GOOGLE_CLOUD_PROJECT=$PROJECT_NUMBER" \
    --set-env-vars="PROJECT_ID=$PROJECT_ID" \
    --set-env-vars="DATASET_ID=$DATASET_ID" \
    --set-env-vars="TABLE_NAME=$TABLE_NAME" \
    --project="$PROJECT_ID" \
    --min-instances=1

  demo_type "Retrieve the service URL and append the /sse path used by MCP clients"
  MCP_SERVER_URL=$(gcloud run services describe "$SERVICE_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --format="get(status.url)")
  MCP_SERVER_URL="${MCP_SERVER_URL}/sse"
  demo_invoke echo "MCP_SERVER_URL=$MCP_SERVER_URL"
  export MCP_SERVER_URL

  demo_wait "MCP server is live and authenticated. Time to wire up an agent."
}

# --- ADK Agent local test ----------------------------------------------------
section_adk_agent() {
  demo_type ""
  demo_type "=== §$SECTION / 6  ADK AGENT + LOCAL TEST ==="
  demo_type "The Agent Development Kit (ADK) is Google's framework for building Gemini agents."
  demo_type "MCPToolset connects an ADK agent to any MCP server over SSE."
  demo_type ""
  demo_type "Connection flow:"
  demo_type "  Agent opens SSE GET /sse → MCP server announces tools → Gemini sees apply_leave"
  demo_type "  Gemini decides to call apply_leave → ADK posts to /messages/ → BigQuery row written"
  demo_wait "Install the ADK and supporting packages"

  demo_invoke pip install --quiet \
    "google-adk==1.5.0" \
    "google-cloud-aiplatform" \
    "google-auth" \
    "requests"

  clear
  demo_type "Review the local test script before running it"
  demo_invoke cat "$ASSETS_DIR/agent_local_test.py"
  demo_type ""
  demo_type "Highlights:"
  demo_type "  fetch_id_token() exchanges our credentials for a short-lived Bearer token"
  demo_type "  accepted by the --no-allow-unauthenticated Cloud Run service"
  demo_type "  AdkApp wraps the agent with the same interface as Agent Engine — test locally first"
  demo_type "  stream_query() yields reasoning events so the audience can follow the chain-of-thought"
  demo_wait "Run the local test — watch Gemini parse natural language and call apply_leave"

  demo_invoke python "$ASSETS_DIR/agent_local_test.py"

  demo_type "Gemini extracted employee ID, start date, and end date from free text,"
  demo_type "then called apply_leave — zero date-parsing code written on our side."
  demo_wait "Confirm the row landed in BigQuery"

  demo_invoke bq query --nouse_legacy_sql \
    "SELECT * FROM \`$PROJECT_ID.$DATASET_ID.$TABLE_NAME\` ORDER BY leave_start_date DESC LIMIT 5"

  demo_wait "Row confirmed. Local integration works — time to go to production."
}

# --- Agent Engine + Gemini Enterprise ----------------------------------------
section_agent_engine() {
  demo_type ""
  demo_type "=== §$SECTION / 6  AGENT ENGINE + GEMINI ENTERPRISE ==="
  demo_type "Agent Engine (Vertex AI Reasoning Engines) is managed hosting for ADK agents."
  demo_type "It handles versioning, scaling, and integrates directly with Gemini Enterprise."
  demo_type ""
  demo_type "Deployment flow:"
  demo_type "  1. AdkApp serialises the agent + tool config"
  demo_type "  2. agent_engines.create() uploads artifacts to STAGING_BUCKET, provisions an endpoint"
  demo_type "  3. The Reasoning Engine resource name is used to register with Gemini Enterprise"
  demo_wait "Review the Agent Engine deployment script"

  demo_invoke cat "$ASSETS_DIR/deploy_agent_engine.py"

  clear
  demo_type "Deploy to Agent Engine — typically takes 2-5 minutes"
  export STAGING_BUCKET
  demo_invoke python "$ASSETS_DIR/deploy_agent_engine.py"

  REASONING_ENGINE_ID=$(cat /tmp/reasoning_engine_id.txt 2>/dev/null)
  demo_invoke echo "REASONING_ENGINE_ID=$REASONING_ENGINE_ID"
  export REASONING_ENGINE_ID

  clear
  demo_type "Agent Engine is live. Now register it with Gemini Enterprise via two REST calls."
  demo_type ""
  demo_type "Call 1 — Authorization resource: lets Gemini Enterprise perform OAuth on behalf of users"
  demo_type "Call 2 — Agent record: links the Reasoning Engine to the Gemini assistant"
  demo_wait "Review the registration script"

  demo_invoke cat "$ASSETS_DIR/register_agent.py"

  demo_type "Run the registration"
  export GEMINI_ENTERPRISE_ENGINE_ID OAUTH_CLIENT_ID OAUTH_CLIENT_SECRET AUTH_ID
  demo_invoke python "$ASSETS_DIR/register_agent.py"

  demo_type ""
  demo_type "Agent is live in Gemini Enterprise."
  demo_wait "Open Gemini Enterprise and try: 'My employee ID is 99, I need leave from 2025-09-01 to 2025-09-05.'"
}

# =============================================================================
# MAIN
# =============================================================================

demo_run() {
  clear
  echo "╔══════════════════════════════════════════════════════════════════╗"
  echo "║       Demo: MCP Server + ADK Agent + Gemini Enterprise           ║"
  echo "╚══════════════════════════════════════════════════════════════════╝"
  demo_type "Project : $PROJECT_ID  ($PROJECT_NUMBER)"
  demo_type "Region  : $REGION"
  demo_type "Bucket  : $STAGING_BUCKET"
  demo_type ""
  demo_type "We'll build an AI-powered leave-management assistant end-to-end:"
  demo_type "  §2  BigQuery       — serverless storage for leave records"
  demo_type "  §4  Cloud Run      — authenticated HTTPS host for the MCP server"
  demo_type "  §6  Agent Engine   — managed agent hosting wired into Gemini Enterprise"
  demo_type ""
  demo_type "Sections §1, §3, and §5 are supporting steps (setup, image build, local test)."
  demo_wait "Ready? Let's go."

  SECTION="1"
  clear
  section_setup

  SECTION="2"
  clear
  section_bigquery

  SECTION="3"
  clear
  section_build_and_push

  SECTION="4"
  clear
  section_cloud_run

  SECTION="5"
  clear
  section_adk_agent

  SECTION="6"
  clear
  section_agent_engine

  demo_type ""
  demo_type "=== ALL DONE ==="
  demo_type ""
  demo_type "What we built:"
  demo_type "  MCP server     FastMCP @tool that persists leave records to BigQuery"
  demo_type "  Cloud Run      Authenticated, always-warm HTTPS endpoint for the MCP server"
  demo_type "  ADK Agent      Gemini + MCPToolset: understands natural-language leave requests"
  demo_type "  Agent Engine   Managed, versioned agent hosting on Vertex AI"
  demo_type "  Gemini Ent.    End-user chat UI — no code required on the user side"
  demo_type ""
  demo_type "Clean up when done:"
  demo_type "  gcloud run services delete $SERVICE_NAME --region=$REGION --project=$PROJECT_ID"
  demo_type "  bq rm -r -f $PROJECT_ID:$DATASET_ID"
  demo_type "  gcloud artifacts repositories delete $REPO_NAME --location=$REGION --project=$PROJECT_ID"
  demo_wait "Or simply: gcloud projects delete $PROJECT_ID"
}

demo_main "$@"
