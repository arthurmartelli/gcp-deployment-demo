#!/usr/bin/env bash

source "$(dirname "$0")/demo.sh"

# Config — set or export these before running if the defaults aren't right
REGION="${REGION?Please set the REGION environment variable to a GCP region (e.g. us-central1)}"
DEVSHELL_PROJECT_ID="${DEVSHELL_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
APP_DIR="$(cd "$(dirname "$0")/app" && pwd)"
IMAGE_BASE="$REGION-docker.pkg.dev/$DEVSHELL_PROJECT_ID/devops-demo"
IMAGE_APP="$IMAGE_BASE/app" # single image name — versioned per section (v0.0, v0.1, v0.2)
SECTION=""

# =============================================================================
# SECTIONS
# =============================================================================

# --- Setup -------------------------------------------------------------------
section_setup() {
  demo_type "=== $SECTION / 6  SETUP ==="
  demo_type "Goal: confirm identity, pull the lab repo, and understand the app we'll deploy."
  demo_type "First, verify which account is active in this shell"
  demo_invoke gcloud auth list

  cd "$APP_DIR" || exit

  clear
  demo_type "The app we're deploying lives in: $APP_DIR"
  demo_wait "Let's understand the app structure"
  demo_invoke ls . templates

  demo_type "main.py — a tiny Flask app: one route, one template, one model dict"
  demo_invoke cat main.py

  demo_type "requirements.txt — Flask is the only runtime dependency"
  demo_invoke cat requirements.txt

  demo_type "Dockerfile — copies source in, installs deps, launches Gunicorn on port 8080"
  demo_invoke cat Dockerfile

  clear
  demo_type "Good habit: build the image locally before touching any cloud service."
  demo_type "Catches Dockerfile errors early and costs nothing."
  demo_invoke docker build -t test-python .
  demo_type "Local build succeeded — we're ready to deploy to GCP."
}

# --- App Engine --------------------------------------------------------------
section_app_engine() {
  demo_type ""
  demo_type "=== $SECTION / 6  APP ENGINE ==="
  demo_type "App Engine is Google's fully-managed PaaS."
  demo_type "You ship code + a tiny config file; GCP handles servers, OS patches, and scaling."
  demo_type "No Dockerfile, no port forwarding, no capacity planning required."
  demo_wait "Let's see just how minimal the config really is"

  cd "$APP_DIR" || exit

  demo_type "The entire App Engine config is one line declaring the runtime."
  cat >"$APP_DIR/app.yaml" <<-'EOF'
		runtime: python312
		EOF
  demo_type "Compare that to the Dockerfile we just read."
  demo_invoke cat app.yaml
  demo_invoke cat Dockerfile

  demo_type "Initialize App Engine for this project (one-time setup per project)"
  demo_invoke gcloud app create --region="$REGION"

  demo_type "Deploying version 'one' — no --no-promote flag means it goes live immediately"
  demo_invoke gcloud app deploy --version=one --quiet

  demo_type "App is live. Now let's simulate a code change — edit the page title."
  demo_invoke grep -n title main.py
  sed -i '8c\    model = {"title": "Hello App Engine"}' "$APP_DIR/main.py"
  demo_invoke grep -n title main.py

  demo_type "Deploy version 'two' with --no-promote."
  demo_type "The new code is built and running, but zero traffic is routed to it yet."
  demo_type "This is the safe-deploy pattern: test before you expose."
  demo_type "Confirm both versions appear side-by-side in the console after this deploys"
  demo_invoke gcloud app deploy --version=two --no-promote --quiet

  demo_type "Traffic splitting lets us shift users gradually (e.g. canary) or all at once."
  demo_type "--splits=two=1 means: send 100% of requests to version two."
  demo_invoke gcloud app services set-traffic default --splits=two=1 --quiet
  demo_wait "Version two is now live. Version one still exists — rollback is instant."
}

# --- Artifact Registry + Cloud Build -----------------------------------------
section_build_and_push() {
  demo_type ""
  demo_type "=== $SECTION / 6  ARTIFACT REGISTRY + CLOUD BUILD ==="
  demo_type "From here on, GCP services need to pull images from somewhere."
  demo_type "Artifact Registry is Google's managed registry for containers (replaces Container Registry)."
  demo_type "Cloud Build compiles and pushes images in the cloud — no local Docker daemon needed."
  demo_wait "Let's create the registry and push our first image"

  cd "$APP_DIR" || exit

  demo_type "Create a Docker-format repository in Artifact Registry"
  demo_type "Images will be stored under: $IMAGE_BASE"
  demo_invoke gcloud artifacts repositories create devops-demo \
    --repository-format=docker \
    --location="$REGION"

  demo_type "Configure the local Docker CLI to authenticate against this registry endpoint"
  demo_invoke gcloud auth configure-docker "$REGION-docker.pkg.dev"

  clear
  demo_type "gcloud builds submit does three things in one command:"
  demo_type "  1. Tars and uploads the build context to Cloud Storage"
  demo_type "  2. Runs the Dockerfile inside a Cloud Build worker (not your machine)"
  demo_type "  3. Pushes the resulting image straight to Artifact Registry"
  demo_invoke gcloud builds submit --tag "$IMAGE_APP:v0.0" .
  demo_wait "Image available at: $IMAGE_APP:v0.0"
}

# --- Cloud Run ---------------------------------------------------------------
section_cloud_run() {
  demo_type ""
  demo_type "=== $SECTION / 6  CLOUD RUN ==="
  demo_type "Cloud Run runs stateless containers on demand — no cluster, no nodes, no ops."
  demo_type "It scales to zero when idle (you're billed nothing) and back up in milliseconds."
  demo_type "Key constraint: containers must be stateless — local disk is ephemeral."
  demo_wait "Deploy the same Flask app as a Cloud Run service"

  cd "$APP_DIR" || exit

  demo_type "Give this version its own title so it's recognisable in the browser"
  demo_invoke grep -n title main.py
  sed -i '8c\    model = {"title": "Hello Cloud Run"}' "$APP_DIR/main.py"
  demo_invoke grep -n title main.py

  demo_type "Build a dedicated image for Cloud Run — same source, new tag"
  demo_invoke gcloud builds submit --tag "$IMAGE_APP:v0.1" .

  demo_type "Waiting ~30 s for Artifact Registry to finish indexing the new image..."
  demo_invoke sleep 30

  demo_type "Why deploy by digest instead of tag?"
  demo_type "  Tags are mutable — 'v0.1' can be overwritten at any time."
  demo_type "  A digest (sha256:...) is a cryptographic hash of the image layers."
  demo_type "  Deploying by digest guarantees you run the exact image you tested."
  demo_wait "Fetch the digest of the image we just pushed"
  image_digest=$(gcloud container images list-tags "$IMAGE_APP" \
    --filter="tags=v0.1" \
    --format='get(digest)' --limit=1)
  demo_invoke echo "$image_digest"

  demo_type "Flags worth knowing:"
  demo_type "  --allow-unauthenticated  public HTTPS endpoint, no auth token needed"
  demo_type "  --max-instances=6        caps horizontal scale to control runaway costs"
  demo_type "  --cpu-boost              grants extra CPU during cold starts to cut latency"
  demo_wait "Deploy — the output will include a public Service URL to test right away"
  demo_invoke gcloud run deploy hello-cloud-run \
    --image="$IMAGE_APP@$image_digest" \
    --allow-unauthenticated \
    --port=8080 \
    --max-instances=6 \
    --cpu-boost \
    --region="$REGION" \
    --project="$DEVSHELL_PROJECT_ID"
  demo_type "Cloud Run printed a Service URL above — open it to confirm 'Hello Cloud Run'."
  demo_wait "Open the URL, then continue"
}

# --- GKE Autopilot -----------------------------------------------------------
section_gke_cluster() {
  demo_type ""
  demo_type "=== $SECTION / 6  GKE AUTOPILOT ==="
  demo_type "GKE has two modes:"
  demo_type "  Standard  — you manage node pools (VM size, count, upgrades)"
  demo_type "  Autopilot — Google manages nodes; you declare Pods and pay per Pod, not per VM"
  demo_type "Autopilot is the recommended default unless you need low-level node control."
  demo_wait "Creating the Autopilot cluster — this typically takes 5-10 minutes, grab a coffee"

  demo_wait gcloud container --project "$DEVSHELL_PROJECT_ID" clusters create-auto autopilot-cluster-1 \
    --region "$REGION" \
    --release-channel regular \
    --network "projects/$DEVSHELL_PROJECT_ID/global/networks/default" \
    --subnetwork "projects/$DEVSHELL_PROJECT_ID/regions/$REGION/subnetworks/default" \
    --cluster-ipv4-cidr /17 \
    --binauthz-evaluation-mode=DISABLED

  demo_type "Cluster is ready. Configure kubectl to point at it."
  demo_type "get-credentials writes a kubeconfig entry — all kubectl commands now target this cluster."
  demo_invoke gcloud container clusters get-credentials autopilot-cluster-1 \
    --region "$REGION" \
    --project "$DEVSHELL_PROJECT_ID"

  demo_type "Node list may be empty right after creation."
  demo_type "Autopilot provisions nodes on first workload — not eagerly on cluster creation."
  demo_invoke kubectl get nodes
  demo_wait "No nodes yet — that's expected and by design. They'll appear once we schedule Pods."
}

# --- Deploy to GKE -----------------------------------------------------------
section_deploy_gke() {
  demo_type ""
  demo_type "=== $SECTION / 6  DEPLOY TO KUBERNETES ==="
  demo_type "Kubernetes is declarative: we describe desired state in a YAML manifest."
  demo_type "The control plane continuously reconciles actual state towards it."
  demo_type ""
  demo_type "Our manifest defines two objects:"
  demo_type "  Deployment — maintains 3 identical Pod replicas; handles rolling updates and restarts"
  demo_type "  Service    — stable network endpoint in front of those Pods (type: LoadBalancer = public IP)"
  demo_wait "Write and review the manifest"

  cd "$APP_DIR" || exit

  demo_type "Give this version its own title so it's recognisable in the browser"
  demo_invoke grep -n title main.py
  sed -i '8c\    model = {"title": "Hello GKE"}' "$APP_DIR/main.py"
  demo_invoke grep -n title main.py

  demo_type "Build a dedicated image for GKE — same source, new tag"
  demo_invoke gcloud builds submit --tag "$IMAGE_APP:v0.2" .

  cat >"$APP_DIR/kubernetes-config.yaml" <<-EOF
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
		        image: $IMAGE_APP:v0.2
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
  demo_type "Notice the selector / matchLabels pattern."
  demo_type "The Service finds Pods by label, not by name — loose coupling by design."
  demo_type "You can scale or replace Pods without ever touching the Service definition."

  demo_wait "Apply the manifest — kubectl will create both objects"
  demo_invoke kubectl apply -f kubernetes-config.yaml

  demo_type "Autopilot provisions nodes on demand."
  demo_type "Pods will show Pending until a node is ready — that's normal, not an error."
  demo_wait "Check Pod status (run again manually if still Pending — nodes take ~2 min)"
  demo_invoke kubectl get pods

  demo_type "The LoadBalancer Service provisions a Google Cloud L4 load balancer."
  demo_type "EXTERNAL-IP will show <pending> until GCP assigns one (~1-2 min)."
  demo_wait "Check Service status — once EXTERNAL-IP is assigned, open it in a browser"
  demo_invoke kubectl get services
  demo_wait "You should see 'Hello GKE' — served by 3 Pods behind a load balancer."
}

# =============================================================================
# MAIN
# =============================================================================

demo_run() {
  clear
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║         Demo: Deploying Projects on GCP              ║"
  echo "╚══════════════════════════════════════════════════════╝"
  demo_type "Project : $DEVSHELL_PROJECT_ID"
  demo_type "Region  : $REGION"
  demo_type ""
  demo_type "We'll deploy the same Flask app three different ways and compare the trade-offs:"
  demo_type "  §2  App Engine    — PaaS, minimal config, built-in traffic splitting"
  demo_type "  §4  Cloud Run     — serverless containers, scales to zero, per-request billing"
  demo_type "  §6  GKE Autopilot — full Kubernetes, managed nodes, most operational flexibility"
  demo_type ""
  demo_wait "Sections §1, §3, and §5 are supporting steps (setup, image build, cluster creation)."

  SECTION="1"
  clear
  section_setup
  SECTION="2"
  clear
  section_app_engine
  SECTION="3"
  clear
  section_build_and_push
  SECTION="4"
  clear
  section_cloud_run
  SECTION="5"
  clear
  section_gke_cluster
  SECTION="6"
  clear
  section_deploy_gke

  demo_type ""
  demo_type "=== ALL DONE ==="
  demo_type ""
  demo_type "Trade-off summary:"
  demo_type "  App Engine    + Simplest config  + Traffic splitting built-in  - Less control"
  demo_type "  Cloud Run     + No infra at all  + Scales to zero              - Stateless only"
  demo_type "  GKE Autopilot + Full K8s power   + No node ops                 - Steeper learning curve"
  demo_type ""
  demo_type "All three run the same code — the choice depends on your operational requirements."
  demo_wait "Explore the console and the live endpoints, then clean up when done:
  gcloud projects delete $DEVSHELL_PROJECT_ID"
}

demo_main "$@"
