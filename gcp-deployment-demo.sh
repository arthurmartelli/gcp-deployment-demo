#!/usr/bin/env bash

source "$(dirname "$0")/demo.sh"

# Config — set or export these before running if the defaults aren't right
REGION="${REGION:-us-central1}"
DEVSHELL_PROJECT_ID="${DEVSHELL_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"

APP_DIR="$HOME/gcp-course/training-data-analyst/courses/design-process/deploying-apps-to-gcp"
IMAGE_BASE="$REGION-docker.pkg.dev/$DEVSHELL_PROJECT_ID/devops-demo"
SECTION=""

# =============================================================================
# SECTIONS
# =============================================================================

# --- Setup -------------------------------------------------------------------
section_setup() {
  demo_wait "=== $SECTION / 6  SETUP ==="
  demo_wait "Confirm the active account, then pull down the lab repo"

  demo_invoke gcloud auth list

  demo_invoke mkdir -p ~/gcp-course
  demo_invoke cd ~/gcp-course
  demo_invoke git clone --depth=1 https://github.com/GoogleCloudPlatform/training-data-analyst.git
  demo_invoke cd "$APP_DIR"

  clear
  demo_wait "Let's understand the app we are deploying"
  demo_invoke ls . templates
  demo_invoke cat main.py
  demo_invoke cat requirements.txt
  demo_invoke cat Dockerfile

  clear
  demo_wait "Quick sanity check — build the image locally before touching any GCP service"
  demo_invoke docker build -t test-python .
}

# --- App Engine --------------------------------------------------------------
section_app_engine() {
  demo_wait "=== $SECTION / 6  APP ENGINE ==="
  demo_wait "App Engine is fully managed — we only supply code and a small config file"

  demo_invoke cd "$APP_DIR"

  demo_wait "The entire App Engine config is one line — just declare the runtime"
  cat >"$APP_DIR/app.yaml" <<-'EOF' # Write app.yaml silently
		runtime: python312
		EOF
  demo_invoke cat app.yaml

  demo_invoke gcloud app create --region="$REGION"
  demo_wait "Open App Engine in the console to watch the deployment"

  demo_wait "Deploy version one — this becomes the live version automatically"
  demo_invoke gcloud app deploy --version=one --quiet

  # sed is done silently — quoting breaks down through $* + eval; grep shows the result
  demo_wait "Change the page title and deploy a second version, but hold traffic back"
  demo_invoke grep -n title main.py
  sed -i '8c\    model = {"title": "Hello App Engine"}' "$APP_DIR/main.py"
  demo_invoke grep -n title main.py

  demo_wait "The --no-promote flag tells App Engine to keep serving the old version"
  demo_invoke gcloud app deploy --version=two --no-promote --quiet

  # Traffic splitting: send everything to v2
  demo_wait "Both versions are live — shift 100% of traffic to version two (--splits=[version]=[weight])"
  demo_invoke gcloud app services set-traffic default --splits=two=1 --quiet
}

# --- Artifact Registry + Cloud Build -----------------------------------------
section_build_and_push() {
  demo_wait "=== $SECTION / 6  ARTIFACT REGISTRY + CLOUD BUILD ==="
  demo_wait "Images are stored in Artifact Registry and built in the cloud via Cloud Build"

  demo_invoke cd "$APP_DIR"

  demo_wait "Update the title so the Kubernetes version is recognisable"
  demo_invoke grep -n title main.py
  sed -i '8c\    model = {"title": "Hello Kubernetes Engine"}' "$APP_DIR/main.py"
  demo_invoke grep -n title main.py

  demo_wait "Create a Docker repository in Artifact Registry"
  demo_invoke gcloud artifacts repositories create devops-demo \
    --repository-format=docker \
    --location="$REGION"

  # Teach Docker how to authenticate against Artifact Registry
  demo_invoke gcloud auth configure-docker "$REGION-docker.pkg.dev"

  clear
  demo_wait "Cloud Build builds and pushes the image remotely (no local Docker daemon needed)"
  demo_invoke gcloud builds submit --tag "$IMAGE_BASE/devops-image:v0.2" .
}

# --- Cloud Run ---------------------------------------------------------------
section_cloud_run() {
  demo_wait "=== $SECTION / 6  CLOUD RUN ==="
  demo_wait "Serverless containers — no cluster to manage, scales to zero, billed per request"

  demo_invoke cd "$APP_DIR"

  # Silently update the title, confirm with grep
  demo_wait "Last title change to identify the Cloud Run version"
  demo_invoke grep -n title main.py
  sed -i '8c\    model = {"title": "Hello Cloud Run"}' "$APP_DIR/main.py"
  demo_invoke grep -n title main.py

  demo_wait "Build and push a dedicated image for Cloud Run"
  demo_invoke gcloud builds submit --tag "$IMAGE_BASE/cloud-run-image:v0.1" .

  # Give Artifact Registry time to index the new image before we query its digest
  demo_wait "Give Artifact Registry 30 s to finish indexing the new image..."
  demo_invoke sleep 30

  # Capture the digest silently — deploying by digest pins an exact, immutable image
  demo_wait "Grab the image digest — more stable than a tag, which can be overwritten"
  image_digest=$(gcloud container images list-tags "$IMAGE_BASE/cloud-run-image" \
    --format='get(digest)' --limit=1)
  demo_invoke echo "$image_digest"

  demo_wait "Deploy — unauthenticated access, max 6 instances, CPU boost on cold starts"
  # Note: if prompted about billing, type 'y' — the APIs should already be enabled in the lab
  demo_invoke gcloud run deploy hello-cloud-run \
    --image="$IMAGE_BASE/cloud-run-image@$image_digest" \
    --allow-unauthenticated \
    --port=8080 \
    --max-instances=6 \
    --cpu-boost \
    --region="$REGION" \
    --project="$DEVSHELL_PROJECT_ID"
}


# --- GKE Autopilot -----------------------------------------------------------
section_gke_cluster() {
  demo_wait "=== $SECTION / 6  GKE AUTOPILOT ==="
  demo_wait "Autopilot provisions and manages nodes for us — we only think about workloads"

  # TODO: prebuild GKE
  demo_invoke gcloud container --project "$DEVSHELL_PROJECT_ID" clusters create-auto autopilot-cluster-1 \
    --region "$REGION" \
    --release-channel regular \
    --network "projects/$DEVSHELL_PROJECT_ID/global/networks/default" \
    --subnetwork "projects/$DEVSHELL_PROJECT_ID/regions/$REGION/subnetworks/default" \
    --cluster-ipv4-cidr /17 \
    --binauthz-evaluation-mode=DISABLED

  demo_wait "Fetch credentials so kubectl knows how to reach the cluster"
  demo_invoke gcloud container clusters get-credentials autopilot-cluster-1 \
    --region "$REGION" \
    --project "$DEVSHELL_PROJECT_ID"

  # Autopilot nodes provision on demand — the list may be empty right after cluster creation
  demo_invoke kubectl get nodes
}

# --- Deploy to GKE -----------------------------------------------------------
section_deploy_gke() {
  demo_wait "=== $SECTION / 6  DEPLOY TO KUBERNETES ==="
  demo_wait "A Deployment (3 replicas) and a LoadBalancer Service — both in one manifest"

  demo_invoke cd "$APP_DIR"
  cat >"$APP_DIR/kubernetes-config.yaml" <<-EOF # Write the manifest silently, then display it
		---
		apiVersion: apps/v1
		kind: Deployment
		metadata:
		  name: devops-deployment
		  labels:
		    app: devops
		    tier: frontend
		spec:
		  replicas: 3
		  selector:
		    matchLabels:
		      app: devops
		      tier: frontend
		  template:
		    metadata:
		      labels:
		        app: devops
		        tier: frontend
		    spec:
		      containers:
		      - name: devops-demo
		        image: $IMAGE_BASE/devops-image:v0.2
		        ports:
		        - containerPort: 8080
		
		---
		apiVersion: v1
		kind: Service
		metadata:
		  name: devops-deployment-lb
		  labels:
		    app: devops
		    tier: frontend-lb
		spec:
		  type: LoadBalancer
		  ports:
		  - port: 80
		    targetPort: 8080
		  selector:
		    app: devops
		    tier: frontend
		EOF

  demo_invoke cat kubernetes-config.yaml

  demo_invoke kubectl apply -f kubernetes-config.yaml

  # Autopilot spins up nodes on demand — pods may stay Pending briefly
  demo_wait "Pods are scheduling — Autopilot will provision nodes if none are ready yet"
  demo_invoke kubectl get pods

  demo_wait "Once provisioned, the LoadBalancer gets an external IP — that's our endpoint"
  demo_invoke kubectl get services
}

# =============================================================================
# MAIN
# =============================================================================

demo_run() {
  demo_type "Demo: Deploying projects on GCP"
  demo_type "Project: $DEVSHELL_PROJECT_ID  |  Region: $REGION"
  demo_wait "Press any key to start the demo, or Ctrl+C to exit"

  SECTION="1"
  section_setup
  SECTION="2"
  section_app_engine
  SECTION="3"
  section_build_and_push
  SECTION="4"
  section_cloud_run
  SECTION="5"
  section_gke_cluster
  SECTION="6"
  section_deploy_gke

  demo_type "=== ALL DONE ==="
  demo_type "App Engine    — managed platform, built-in traffic splitting"
  demo_type "GKE Autopilot — Kubernetes without node operations"
  demo_type "Cloud Run     — serverless containers, zero infrastructure"
  demo_wait "Feel free to explore the console, check out the deployed workloads,
    and tear down the resources when you're done (gcloud projects delete $DEVSHELL_PROJECT_ID)"
}

demo_main "$@"
