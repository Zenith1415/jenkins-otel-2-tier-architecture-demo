## Architecture

    Jenkins (OTel plugin)               namespace: jenkins
        | OTLP :4317
        v
    Tier-1: DaemonSet                   namespace: observability
      batch -> loadbalancingexporter
      hash(trace_id) -> same gateway pod
        |
        v
    Tier-2: Deployment (2 replicas)     namespace: observability
      1. spanmetrics (ALL spans -> RED metrics)
      2. tail_sampling (errors=keep, slow=keep, rest=20%)
        |              |
        v              v
    Prometheus      Jaeger              namespace: monitoring
    (DORA metrics)  (sampled traces)

### Why this architecture

- **Two tiers:** tail sampling needs all spans of a trace on the same Collector. loadbalancingexporter hashes trace_id for consistent routing.
- **DaemonSet for Tier-1:** one agent per node, Jenkins pods send to localhost.
- **Headless Service:** clusterIP: None returns pod IPs. Regular ClusterIP would randomly distribute and break sampling.
- **spanmetrics before sampling:** metrics count all spans (accurate). Sampling only affects trace storage.

---

## Prerequisites

- Docker
- kind — https://kind.sigs.k8s.io
- kubectl

## Quick Start

### Option A: Fully Automated

    cd deployment
    bash setup.sh        # Creates cluster + deploys K8s resources
    bash run-tests.sh    # Installs plugins + creates pipelines + runs tests

### Option B: Manual Pipeline Creation

    cd deployment
    bash setup.sh

Then in Jenkins UI:
1. Install plugins: OpenTelemetry, Pipeline, Configuration as Code
2. Restart Jenkins
3. Apply JCasC: Manage Jenkins → Configuration as Code → path: `/var/jenkins_home/casc.yaml`
4. Create each pipeline manually:
   - New Item → name (e.g. `01-happy-path`) → Pipeline → OK
   - Paste script from `pipelines/01-happy-path.groovy`
   - Save → Build Now

## Post-Setup: Install Plugins

1. Go to Jenkins -> Manage Jenkins -> Plugins -> Available
2. Install: **OpenTelemetry**, **Pipeline**, **Configuration as Code**
3. Restart Jenkins
4. Go to Manage Jenkins -> Configuration as Code -> Path: /var/jenkins_home/casc.yaml -> Apply

## Creating Test Pipelines

Pipeline scripts are in the pipelines/ folder. For each one:

1. Jenkins -> New Item -> enter name (e.g. 01-happy-path) -> Pipeline -> OK
2. Scroll to Pipeline section -> paste the contents of the .groovy file
3. Save -> Build Now

---

## Test Cases

| # | Pipeline | What it tests | Sampling policy |
|---|----------|---------------|-----------------|
| 01 | happy-path | Span tree, TRACEPARENT per stage | probabilistic 20% |
| 02 | error-trace | Error retention | errors-keep (100%) |
| 03 | slow-build | Latency retention (65s) | slow-traces-keep |
| 04 | parallel | Context propagation in threads | probabilistic 20% |
| 05 | try-catch | Caught error is not build failure | probabilistic |
| 06 | nested | 3-level span hierarchy | probabilistic 20% |
| 07 | withenv | TRACEPARENT in withEnv block | probabilistic 20% |
| 08 | volume-test | Run 10x: ~2 in Jaeger, all 10 in Prometheus | probabilistic 20% |

---

## Verification Commands

    # DaemonSet: one agent per worker node
    kubectl get ds -n observability

    # Headless Service: clusterIP = None
    kubectl get svc otel-gateway-headless -n observability

    # DNS returns individual pod IPs
    kubectl run dns-test --rm -it --image=busybox --restart=Never -- nslookup otel-gateway-headless.observability.svc.cluster.local

    # Agents on different nodes
    kubectl get pods -n observability -o wide

    # HPA configured
    kubectl get hpa -n observability

---

## Key Observation (Test 08)

Run 08-volume-test 10 times. Then check:

- **Jaeger:** ~2 of 10 traces visible (20% sampling working)
- **Prometheus:** jenkins_ci_calls_total shows all 10

This proves spanmetrics runs before sampling. Metrics are accurate, traces are cost-efficient. If reversed, Prometheus would also show only ~2.

---

## DORA Metrics (PromQL)

    # Deployment frequency (builds per minute)
    rate(jenkins_ci_calls_total[5m]) * 60

    # Change failure rate
    sum(jenkins_ci_calls_total{status_code="STATUS_CODE_ERROR"}) / sum(jenkins_ci_calls_total)

    # Build duration p50
    histogram_quantile(0.50, rate(jenkins_ci_duration_bucket[5m]))

    # Build duration p95
    histogram_quantile(0.95, rate(jenkins_ci_duration_bucket[5m]))

---

## File Structure

    deployment/
    ├── cluster.yaml                   # kind cluster (1 CP + 2 workers)
    ├── setup.sh                       # one-command deploy
    ├── k8s/
    │   ├── base/namespaces.yaml       # jenkins, observability, monitoring
    │   ├── tier-1/
    │   │   ├── configmap.yaml         # agent config (batch + loadbalancing)
    │   │   └── daemonset.yaml         # DaemonSet + Service
    │   ├── tier-2/
    │   │   ├── configmap.yaml         # gateway config (spanmetrics + tail sampling)
    │   │   └── deployment.yaml        # Deployment + headless Service + HPA
    │   ├── backends/backends.yaml     # Jaeger + Prometheus + RBAC
    │   └── jenkins/jenkins.yaml       # Jenkins + JCasC + OTel plugin
    ├── pipelines/                     # 8 test pipeline scripts (.groovy)
    └── observations/                  # screenshots go here

---

## Production vs PoC

| Parameter | This PoC | Production (ci.jenkins.io) |
|-----------|----------|---------------------------|
| Tier-1 | DaemonSet on kind | DaemonSet (AKS) + systemd (VM) |
| Tier-2 replicas | 2 | 2-6 (HPA) |
| decision_wait | 30s | 30s |
| num_traces | 10000 | 50000 |
| sampling | 20% | 10% |
| Config mgmt | kubectl apply | Helm + Puppet/Hiera |

---
---

## Observations & Findings

### Observation 1: Span Tree Structure (Test 01)

The OTel plugin correctly creates a hierarchical span tree for pipeline execution:

    BUILD 01-happy-path (root span, 7.74s)
    └── Phase: Start (784μs)
    └── Phase: Run
        └── Agent (7.5s)
            └── Agent Allocation (25.42ms)
            └── Stage: Checkout (2.19s)
            │   └── sh (2.13s)
            └── Stage: Build (3.08s)
            │   └── sh (3.03s)
            └── Stage: Test (2.08s)
                └── sh (2.03s)
    └── Phase: Finalise (19.23ms)

12 spans total, 5 depth levels. Each stage and step is correctly nested under its parent. The trace duration matches the sum of stage durations (2+3+2 = ~7s).

### Observation 2: Error Propagation (Test 02)

When `sh 'exit 1'` fails in the Deploy stage:
- The `sh` step span gets ERROR status
- The error propagates UP: Stage: Deploy → Agent → BUILD all show ERROR
- Stage: Setup (before the failure) remains OK
- Stage: Verify gets ERROR status because the build was aborted before it could execute normally
- The root span shows ERROR with 5 error spans total

This is important for the `errors-keep` tail sampling policy, the root span's ERROR status is what triggers 100% retention.

### Observation 3: Slow Build Retention (Test 03)

The slow build (65s) produces a trace with duration 1m 5s. The `slow-traces-keep` policy with `threshold_ms: 60000` correctly identifies this as a slow trace. In production with 20% sampling, this trace would always be retained regardless of probabilistic sampling.

### Observation 4: Parallel Branch Isolation (Test 04)

Three parallel branches (Unit, Integration, Lint) execute concurrently:
- All three branches start at nearly the same time (~4.35s mark)
- They overlap in the Jaeger waterfall view
- Total trace duration is 4.88s (max of branches), NOT 9s (sum of branches)
- Each branch gets its own span subtree: Parallel branch → Stage → sh
- 16 spans total, depth 7

This confirms the OTel plugin handles CPS-forked threads correctly for span creation.

### Observation 5: Try/Catch Error Handling (Test 05)

When `sh 'exit 1'` fails inside a try/catch block:
- The first `sh` step shows ERROR (red icon)
- The second `sh` step (recovery) shows OK
- Stage: Verify executes and succeeds
- The BUILD root span does NOT show ERROR, the build succeeded overall

This is significant for DORA metrics: a caught error should NOT count as a deployment failure. The `errors-keep` sampling policy correctly does not trigger because the root span status is OK, not ERROR.

### Observation 6: Nested Stage Hierarchy (Test 06)

Three-level nesting works correctly:
- BUILD → Stage: Outer → Stage: Inner Compile → sh
- BUILD → Stage: Outer → Stage: Inner Test → sh
- Inner stages are children of Outer, not of the root
- 11 spans, depth 6

### Observation 7: withEnv Interaction (Test 07)

The `withEnv` block does not interfere with trace structure. The span tree shows Stage: Deploy → sh with the trace intact. TRACEPARENT environment variable is accessible inside the withEnv block alongside custom variables (MY_VAR).

### Observation 8: TRACEPARENT Propagation Bug (PR #1219 Proof)

From the console output of Test 01, the TRACEPARENT environment variable across all three stages:

    Checkout: 00-44a317266e1f4221616fb82795fa7b03-5b9d9af6acf95767-01
    Build:    00-44a317266e1f4221616fb82795fa7b03-5b9d9af6acf95767-01
    Test:     00-44a317266e1f4221616fb82795fa7b03-5b9d9af6acf95767-01

The parent-span-id field (5b9d9af6acf95767) is IDENTICAL across all stages. It points to the BUILD root span and never updates when entering a new stage.

This means any external tool (Maven OTel extension, otel-cli, Ansible callback) that reads env.TRACEPARENT would create child spans under the BUILD root, not under the current stage. The trace hierarchy for external tools is flat.

My PR #1219 (approved by kuisathaverat) fixes this by replacing `otelTraceService.getSpan(run)` with `Span.current()` in OtelEnvironmentContributor.java. After the fix, each stage would have a unique parent-span-id matching that stage's span.

### Observation 9: Sampling vs Metrics — The Key Proof (Test 08)

Ran 08-volume-test 10 times with 20% probabilistic sampling:

- **Jaeger:** 1 trace visible out of 10 builds
- **Prometheus:** jenkins_ci_calls_total shows 10 (all builds counted)

This proves the spanmetrics-before-sampling pipeline ordering works correctly:
1. spanmetrics connector sees ALL 10 traces and generates accurate calls_total = 10
2. tail_sampling then drops ~80% of traces for storage efficiency
3. Only ~20% reach Jaeger, but Prometheus metrics are unaffected

If the ordering were reversed (sampling before metrics), Prometheus would show ~2 instead of 10, making DORA metrics inaccurate.

### Observation 10: Two-Tier Topology Validation

Verified using kubectl:

- DaemonSet `otel-agent` shows DESIRED=2, CURRENT=2, one agent per worker node
- Headless Service `otel-gateway-headless` shows clusterIP=None, returns individual pod IPs for loadbalancingexporter
- HPA `otel-gateway-hpa` configured with min=2, max=6 replicas
- Agent pods are on different nodes (otel-jenkins-poc-worker, otel-jenkins-poc-worker2)

The loadbalancingexporter in Tier-1 uses DNS resolution against the headless Service to discover Tier-2 pod IPs and consistently hash trace_ids for routing.

---

## Architecture Validation Observations

The following observations validate that the local deployment correctly implements the two-tier topology from the GSoC proposal, and explain how this local setup acts as a faithful substitute for ci.jenkins.io.

### Observation 11: DaemonSet Distribution

    $ kubectl get ds -n observability -o wide
    NAME         DESIRED   CURRENT   READY   AVAILABLE   NODE SELECTOR
    otel-agent   2         2         2       2           <none>

    $ kubectl get pods -n observability -o wide
    NAME                             NODE
    otel-agent-kqrf5                 otel-jenkins-poc-worker2
    otel-agent-qfx8x                 otel-jenkins-poc-worker
    otel-gateway-7c67b959d9-8prnp    otel-jenkins-poc-worker2
    otel-gateway-7c67b959d9-vxwlr    otel-jenkins-poc-worker

The DaemonSet shows DESIRED=2, CURRENT=2, exactly one agent pod per worker node. The agent pods are distributed across `worker` and `worker2`, which is the correct behavior.

In production on the AKS `publick8s` cluster, this scales automatically: if the cluster has 20 nodes, the DaemonSet would have 20 agents. Jenkins build agent pods on each node send OTLP to localhost (via `hostNetwork` or node-local routing), resulting in zero cross-node traffic for raw span data.

### Observation 12: Headless Service DNS Resolution

    $ kubectl run dns-test --rm -i --image=busybox --restart=Never -- \
        nslookup otel-gateway-headless.observability.svc.cluster.local

    Name:    otel-gateway-headless.observability.svc.cluster.local
    Address: 10.244.2.4
    Name:    otel-gateway-headless.observability.svc.cluster.local
    Address: 10.244.1.2

This is the proof that the headless Service works correctly for loadbalancingexporter. Instead of returning a single virtual ClusterIP (which would cause kube-proxy to randomly distribute connections and break trace routing), the DNS query returns TWO individual pod IPs, one per gateway replica.

The loadbalancingexporter in Tier-1 periodically re-queries this DNS name. When a gateway pod dies or a new one scales up, the resolver picks up the change and recomputes the hash ring. Only ~1/N of traces get remapped to different pods, existing traces stay on their current pod.

If this were a regular ClusterIP Service (clusterIP: auto instead of None), the nslookup would return a single IP like `10.96.50.134`, and the loadbalancingexporter would be unable to discover individual pods. Tail sampling would be broken.

### Observation 13: HPA Configuration

    $ kubectl describe hpa otel-gateway-hpa -n observability
    Reference:        Deployment/otel-gateway
    Min replicas:     2
    Max replicas:     6
    Metrics:
      cpu:    <unknown> / 70%
      memory: <unknown> / 75%
    Conditions:
      AbleToScale:    True
      ScalingActive:  False (FailedGetResourceMetric)

The HPA is correctly configured to scale between 2 and 6 replicas based on CPU (70%) and memory (75%). The `ScalingActive: False` is expected in a kind cluster as the metrics-server is not installed by default.

In production on AKS, metrics-server is enabled and HPA actively scales. During ci.jenkins.io build spikes (e.g. release day, multiple parallel jobs), the gateway scales up automatically. Since the loadbalancingexporter uses DNS resolution, new pods are discovered within one refresh interval (~5s) and start receiving traffic.

To enable HPA in this local setup:

    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

### Observation 14: Namespace Isolation

Three namespaces separate concerns as designed:

    observability:
      - 2 otel-agent pods (DaemonSet)
      - 2 otel-gateway pods (Deployment, ReplicaSet)
      - Service: otel-agent (ClusterIP 10.96.50.134)
      - Service: otel-gateway-headless (ClusterIP None)
      - HPA: otel-gateway-hpa

    monitoring:
      - jaeger pod
      - prometheus pod
      - Services: jaeger (NodePort 30686), prometheus (NodePort 30090)

    jenkins:
      - jenkins pod
      - Service: jenkins (NodePort 30080)

This separation matches the GSoC proposal. In production:
- The `jenkins` namespace would be managed by the Jenkins infra team (Puppet for VMs, Helm for AKS)
- The `observability` namespace would be a shared Collector fleet, potentially used by other teams beyond Jenkins
- The `monitoring` namespace would integrate with existing Jenkins Infra monitoring (currently Datadog on Azure VMs)

### Observation 15: Trace Routing Validation

The gateway logs confirm the spanmetrics connector is wired correctly:

    info  spanmetricsconnector/connector.go:109
      Building spanmetrics connector
      {"exporter_in_pipeline": "traces", "receiver_in_pipeline": "metrics"}

This confirms the critical pipeline topology:
- spanmetrics acts as an **exporter** in the traces pipeline (receives all spans)
- spanmetrics acts as a **receiver** in the metrics pipeline (emits RED metrics)
- This is the connector pattern — the bridge between the two signal types

### Observation 16: Resource Limits & Production Parity

Current resource allocation:

| Component | Request CPU | Limit CPU | Request RAM | Limit RAM |
|-----------|-------------|-----------|-------------|-----------|
| otel-agent (Tier-1) | 100m | 500m | 256Mi | 512Mi |
| otel-gateway (Tier-2) | 250m | 1000m | 512Mi | 2Gi |
| jenkins | 500m | 2000m | 1Gi | 2Gi |
| jaeger | 100m | 500m | 256Mi | 1Gi |

The gateway's 2Gi memory limit is deliberately generous because tail sampling buffers traces in memory (`num_traces: 10000` means up to 10000 traces are held for `decision_wait: 30s`). At 10KB per trace average, that's ~100MB for the buffer alone, plus processing overhead.

In production on AKS, `num_traces: 50000` would require ~500MB buffer, so the limit should increase to 4Gi. The `memory_limiter` processor (limit_mib: 1500, spike_limit: 400) provides a safety valve that drops data before the pod hits its Kubernetes memory limit.

---

## Local as Substitute for ci.jenkins.io

The local setup is a faithful substitute because it preserves every architectural property that matters:

### What This Local Setup Proves

| Production property | Proven locally? | How |
|---------------------|----------------|-----|
| Two-tier topology | Yes | DaemonSet (Tier-1) + Deployment (Tier-2) |
| One agent per node | Yes | 2 worker nodes → 2 agent pods via DaemonSet |
| Trace-aware routing | Yes | loadbalancingexporter with routing_key: traceID |
| Headless Service discovery | Yes | nslookup returns 2 pod IPs, not a ClusterIP |
| spanmetrics before sampling | Yes | Test 08: Prometheus=10, Jaeger=1 |
| Error retention policy | Yes | Test 02 always in Jaeger regardless of sampling |
| Latency retention policy | Yes | Test 03 (65s) always in Jaeger |
| Probabilistic sampling | Yes | Test 08: ~20% retention rate |
| TRACEPARENT bug (PR #1219) | Yes | Test 01 console shows frozen parent-span-id |
| DORA metric derivation | Yes | PromQL on jenkins_ci_calls_total |

### What Production Adds Beyond This

These are environmental differences that don't change the architecture:

| Property | Local (this PoC) | Production (ci.jenkins.io) |
|----------|------------------|----------------------------|
| Cluster | kind (3 nodes) | AKS `publick8s` (N nodes) |
| Gateway replicas | 2 (fixed) | 2-6 (auto-scaled by HPA) |
| Sampling rate | 20% | 10% (lower due to higher volume) |
| decision_wait | 30s | 30s (same) |
| num_traces | 10000 | 50000 (higher memory ceiling) |
| Config management | kubectl apply | Helm + Puppet/Hiera |
| Backends | Jaeger all-in-one | Jaeger production setup |
| Jenkins controller | Single pod on K8s | Azure VM managed by Puppet |
| Build volume | Manual triggers | 1000s of builds/day |

None of these change the architectural decisions, they are volume and operational tuning.

### Why kind Specifically

The kind cluster was chosen because:

1. **Real Kubernetes API** — unlike Docker Compose, kind runs actual kubelet, kube-proxy, kube-dns, CoreDNS, and CNI. DaemonSets, HPAs, and headless Services behave identically to production.
2. **Multiple nodes** — 2 worker nodes prove DaemonSet scheduling. Docker Compose cannot simulate this.
3. **Deterministic setup** — Single YAML cluster config (`cluster.yaml`), reproducible across macOS, Linux, Windows.
4. **Fast iteration** — Full cluster rebuild in ~60 seconds.

### What Cannot Be Tested Locally

Fair acknowledgement of limitations:

- **Network partitions between Azure regions** — requires real multi-region deployment
- **Actual build volume at ci.jenkins.io scale** — our 10-build test is symbolic; production sees thousands of builds daily
- **Long-term trace storage** — Jaeger all-in-one uses in-memory storage, lost on restart; production needs Elasticsearch or Cassandra backing
- **Puppet/Hiera integration for Azure VMs** — ci.jenkins.io controller runs on a VM, not K8s. The JCasC yaml and Collector systemd configs would be Puppet-managed

These are integration concerns that would be validated during the GSoC implementation phase against the actual ci.jenkins.io infrastructure.

### The Core Validation

The architecture's correctness rests on one testable claim: **spanmetrics before tail_sampling preserves accurate metrics while enabling cost-efficient trace storage**. Test 08 proves this unambiguously — 10 builds, all counted, but only 1 trace stored. This proof holds at any scale.

## Teardown

    kind delete cluster --name otel-jenkins-poc