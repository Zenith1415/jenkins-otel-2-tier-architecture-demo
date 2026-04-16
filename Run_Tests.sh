#!/bin/bash
set -e

JENKINS_URL="http://localhost:8080"
AUTH="admin:admin"

echo "======================================================"
echo "  Automated Test Runner"
echo "  Installs plugins, creates pipelines, runs all tests"
echo "======================================================"


# Step 1: Install plugins via Jenkins CLI

echo ""
echo "[1/4] Installing plugins (OpenTelemetry, Pipeline, JCasC)"

# Get the Jenkins pod name
JENKINS_POD=$(kubectl get pods -n jenkins -l app=jenkins -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n jenkins $JENKINS_POD -- jenkins-plugin-cli --plugins \
  opentelemetry \
  workflow-aggregator \
  configuration-as-code \
  pipeline-stage-view \
  git 2>&1 | tail -5 || echo "  (plugins may already be installed)"

echo "  Restarting Jenkins to load plugins"
kubectl rollout restart deployment/jenkins -n jenkins
echo "  Waiting for Jenkins to come back up"
sleep 30
kubectl wait --for=condition=available deployment/jenkins -n jenkins --timeout=180s

# Wait for Jenkins HTTP to respond
echo "  Waiting for Jenkins HTTP to be ready..."
until curl -s -o /dev/null -w "%{http_code}" $JENKINS_URL/login 2>/dev/null | grep -q "200"; do
  sleep 5
  echo "  ...waiting"
done


# Step 2: Apply JCasC
echo ""
echo "[2/4] Applying JCasC configuration..."
CRUMB=$(curl -s -u $AUTH "${JENKINS_URL}/crumbIssuer/api/json" | python -c "import sys,json; print(json.load(sys.stdin)['crumb'])" 2>/dev/null || echo "")

curl -s -X POST -u $AUTH \
  -H "Jenkins-Crumb: ${CRUMB}" \
  "${JENKINS_URL}/configuration-as-code/reload" 2>/dev/null || true
sleep 3


# Step 3: Create pipelines via REST API
echo ""
echo "[3/4] Creating 8 test pipelines..."

create_pipeline() {
  local name=$1
  local script_file=$2

  # Build job config XML
  local script_content=$(cat "pipelines/${script_file}")
  local config_xml=$(cat <<EOF
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description></description>
  <keepDependencies>false</keepDependencies>
  <properties/>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps">
    <script><![CDATA[${script_content}]]></script>
    <sandbox>true</sandbox>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>
EOF
)

  # Delete if exists
  curl -s -X POST -u $AUTH \
    -H "Jenkins-Crumb: ${CRUMB}" \
    "${JENKINS_URL}/job/${name}/doDelete" 2>/dev/null || true

  # Create
  echo "  Creating: ${name}"
  echo "$config_xml" | curl -s -X POST -u $AUTH \
    -H "Jenkins-Crumb: ${CRUMB}" \
    -H "Content-Type: application/xml" \
    --data-binary @- \
    "${JENKINS_URL}/createItem?name=${name}" > /dev/null
}

create_pipeline "01-happy-path" "01-happy-path.groovy"
create_pipeline "02-error-trace" "02-error-trace.groovy"
create_pipeline "03-slow-build" "03-slow-build.groovy"
create_pipeline "04-parallel" "04-parallel.groovy"
create_pipeline "05-try-catch" "05-try-catch.groovy"
create_pipeline "06-nested" "06-nested.groovy"
create_pipeline "07-withenv" "07-withenv.groovy"
create_pipeline "08-volume-test" "08-volume-test.groovy"


# Step 4: Trigger all pipelines

echo ""
echo "[4/4] Triggering pipelines..."

trigger() {
  local job=$1
  echo "  Running: ${job}"
  curl -s -X POST -u $AUTH \
    -H "Jenkins-Crumb: ${CRUMB}" \
    "${JENKINS_URL}/job/${job}/build" > /dev/null
}

trigger "01-happy-path"
sleep 2
trigger "02-error-trace"
sleep 2
# Skip 03-slow-build by default (65s)
trigger "03-slow-build"
# sleep 2
trigger "04-parallel"
sleep 2
trigger "05-try-catch"
sleep 2
trigger "06-nested"
sleep 2
trigger "07-withenv"
sleep 2

echo ""
echo "  Running 08-volume-test 10 times for sampling proof..."
for i in $(seq 1 10); do
  trigger "08-volume-test"
  sleep 1
done

echo ""
echo "  All pipelines triggered. Wait ~60s for completion."
echo ""
echo "  Verify in:"
echo "    Jaeger:     http://localhost:16686"
echo "    Prometheus: http://localhost:9090"
echo ""
echo "  Key observation for Test 08:"
echo "    Jaeger: ~2 traces (20% sampling)"
echo "    Prometheus: jenkins_ci_calls_total{span_name=~\".*volume.*\"} = 10"
