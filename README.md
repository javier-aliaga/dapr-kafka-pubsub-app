# dapr-kafka-pubsub-app

Reproduction harness for a Dapr 1.17 Kafka consumer regression: messages are
abandoned (Kafka offset committed without the handler completing) when a
subscriber pod is rolled with `kubectl rollout restart`.

## What it does

A publisher and a subscriber, both Dapr-enabled, exchange messages over a
Strimzi-deployed Kafka cluster. Every published `seq` is tracked in Redis
(`SADD`) and removed by the subscriber after successful processing (`SREM`).
After draining, any keys remaining in Redis are messages that were lost —
i.e. abandoned during a rollout.

```
                   ┌──────────────────────────────────────────────┐
                   │                  Kind cluster                │
                   │                                              │
  publisher ──┐    │  topic1 (8 part.)   topic2   topic3   topic4 │
              │    │       │               │       │        │     │
              ▼    │       ▼               ▼       ▼        ▼     │
  Dapr sidecar ───────► Strimzi Kafka ───────► Dapr sidecar ──── subscriber
              │    │                                              │
              └──► Redis (set:topicN of in-flight seqs) ◄──── SREM on done
                   │                                              │
                   └──────────────────────────────────────────────┘
```

## Prerequisites

- A `kind` cluster with a local registry at `localhost:5001` (we used the
  standard `kind-with-registry.sh` setup).
- Dapr control plane installed (`dapr init -k`).
- Strimzi installed and a `Kafka` custom resource named `my-cluster` running
  in the `kafka` namespace, reachable at
  `my-cluster-kafka-bootstrap.kafka:9092`.
  See https://strimzi.io/quickstarts/.
- `kubectl`, `docker`, and Go 1.26+ on the host.

## Layout

```
.
├── publisher/        Go app, parallel workers; SADD seq, then PublishEvent
├── subscriber/       Go app, Dapr HTTP service for 4 topics; SREM on done
├── k8s/              Component, Deployments, Redis
├── Makefile          Build / push / deploy / reset / experiment helpers
└── reconcile.sh      Optional log-based reconciliation (legacy)
```

## Quick start

```bash
make build push        # build images for linux/arm64, push to localhost:5001
make deploy            # apply Redis, Component, both Deployments
make reset             # full clean slate: redis flush + topics + consumer group
# wait for publisher to log "FINISHED publishing 100000 messages"
kubectl scale deploy/subscriber --replicas=3
make rollout-loop      # cycle subscriber every 2 minutes
make watch-abandoned   # in another terminal — counts per topic
```

## Reproduction recipe

1. `make reset` — recreates topics, flushes Redis, restarts publisher.
2. Wait for `FINISHED publishing N messages`.
3. `kubectl scale deploy/subscriber --replicas=3` — multiple replicas force
   real partition rebalancing on each rollout.
4. While subscriber is mid-drain, run `make rollout-loop ROLLOUT_INTERVAL=60`.
5. After several rollouts, check `make abandoned` — non-zero counts are
   messages whose Kafka offset got committed without the SREM ever running.

To validate, switch the daprd sidecar back to the fixed version and repeat —
should hold at 0.

## Tunables

| Knob                                           | Where                       | Default | Effect                                              |
|------------------------------------------------|-----------------------------|---------|-----------------------------------------------------|
| `TOTAL_PER_TOPIC`                              | `k8s/publisher.yaml` env    | 25000   | Total messages = `TOTAL_PER_TOPIC * 4`              |
| `WORKERS`                                      | `k8s/publisher.yaml` env    | 8       | Parallel publish goroutines                         |
| `PUBLISH_INTERVAL_MS`                          | `k8s/publisher.yaml` env    | 0       | Sleep per worker between sends; 0 = full speed      |
| `PROCESS_DELAY_MS`                             | `k8s/subscriber.yaml` env   | 100     | Per-message handler latency — controls in-flight    |
| `dapr.io/block-shutdown-duration`              | `k8s/subscriber.yaml` ann.  | 10s     | How long daprd holds SIGTERM before draining        |
| `dapr.io/graceful-shutdown-seconds`            | `k8s/subscriber.yaml` ann.  | 5       | Daprd graceful-stop budget after block window       |
| `terminationGracePeriodSeconds`                | `k8s/subscriber.yaml` spec  | 30      | Must be ≥ block + graceful + buffer                 |
| `PARTITIONS`                                   | Make var                    | 8       | Partitions per topic (more = more rebalance churn)  |

## Make targets

| Target                | What it does                                                         |
|-----------------------|----------------------------------------------------------------------|
| `tidy`                | `go mod tidy` in both apps                                           |
| `build` / `push`      | Buildx for `linux/arm64` and push to `localhost:5001`                |
| `deploy` / `undeploy` | Apply / delete all manifests                                         |
| `reset`               | Scale to 0, flush Redis, delete consumer group, recreate topics, scale publisher |
| `rollout`             | `kubectl rollout restart deploy/subscriber`                          |
| `rollout-loop`        | Loop the rollout (default every 120s)                                |
| `abandoned`           | Print `SCARD` per topic — abandoned message counts                   |
| `abandoned-sample`    | Print sample seqs still in each set                                  |
| `watch-abandoned`     | Polling watch of SCARD (no `watch` binary required)                  |
| `kafka-create-topics` / `kafka-delete-topics` / `kafka-describe-topics` | Topic admin via `kafka-topics.sh` |
| `kafka-reset-group`   | Delete the `subscriber` consumer group                               |
| `redis-flush`         | `FLUSHALL` on the in-cluster Redis                                   |
| `logs-pub` / `logs-sub` / `logs-sub-daprd` / `logs-sub-daprd-prev`     | Log shortcuts |

## Notes on shutdown coordination

The subscriber **does not** call `s.GracefulStop()` on SIGTERM. It keeps
its HTTP server up so daprd can deliver in-flight messages back to it
during `block-shutdown-duration`. The kubelet ends the process via
SIGKILL when `terminationGracePeriodSeconds` expires. Closing the app
HTTP server early causes its own brand of abandoned messages — easy to
mistake for the dapr regression.

Required relationship:
```
terminationGracePeriodSeconds ≥ block-shutdown-duration + graceful-shutdown-seconds + buffer
```
