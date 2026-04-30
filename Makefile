REGISTRY ?= localhost:5001
PLATFORM ?= linux/arm64
PUBLISHER_IMG ?= $(REGISTRY)/dapr-kafka/publisher:latest
SUBSCRIBER_IMG ?= $(REGISTRY)/dapr-kafka/subscriber:latest

.PHONY: tidy build-publisher build-subscriber build push deploy undeploy logs-pub logs-sub rollout reproduce

tidy:
	cd publisher && go mod tidy
	cd subscriber && go mod tidy

build-publisher:
	docker buildx build --platform $(PLATFORM) -t $(PUBLISHER_IMG) --load ./publisher

build-subscriber:
	docker buildx build --platform $(PLATFORM) -t $(SUBSCRIBER_IMG) --load ./subscriber

build: build-publisher build-subscriber

push:
	docker push $(PUBLISHER_IMG)
	docker push $(SUBSCRIBER_IMG)

deploy:
	kubectl apply -f k8s/redis.yaml
	kubectl rollout status deploy/redis --timeout=60s
	kubectl apply -f k8s/kafka-pubsub.yaml
	kubectl apply -f k8s/subscriber.yaml
	kubectl apply -f k8s/publisher.yaml

undeploy:
	-kubectl delete -f k8s/publisher.yaml
	-kubectl delete -f k8s/subscriber.yaml
	-kubectl delete -f k8s/kafka-pubsub.yaml
	-kubectl delete -f k8s/redis.yaml

abandoned:
	@for t in topic1 topic2 topic3 topic4; do \
		n=$$(kubectl exec deploy/redis -- redis-cli SCARD set:$$t); \
		echo "$$t abandoned=$$n"; \
	done

WATCH_INTERVAL ?= 2
watch-abandoned:
	@while true; do \
		clear; \
		date; \
		for t in topic1 topic2 topic3 topic4; do \
			n=$$(kubectl exec deploy/redis -- redis-cli SCARD set:$$t); \
			echo "$$t = $$n"; \
		done; \
		sleep $(WATCH_INTERVAL); \
	done

abandoned-sample:
	@for t in topic1 topic2 topic3 topic4; do \
		echo "--- $$t (first 20) ---"; \
		kubectl exec deploy/redis -- redis-cli SRANDMEMBER set:$$t 20; \
	done

redis-flush:
	kubectl exec deploy/redis -- redis-cli FLUSHALL

KAFKA_NS ?= kafka
KAFKA_POD = $$(kubectl get pods -n $(KAFKA_NS) -l strimzi.io/kind=Kafka -o jsonpath='{.items[0].metadata.name}')

kafka-reset-group:
	kubectl scale deploy/subscriber --replicas=0
	-kubectl exec -n $(KAFKA_NS) $(KAFKA_POD) -- bin/kafka-consumer-groups.sh \
		--bootstrap-server localhost:9092 --delete --group subscriber
	@echo "consumer group deleted; bring subscriber back with: kubectl scale deploy/subscriber --replicas=1"

kafka-delete-topics:
	for t in topic1 topic2 topic3 topic4; do \
		kubectl exec -n $(KAFKA_NS) $(KAFKA_POD) -- bin/kafka-topics.sh \
			--bootstrap-server localhost:9092 --delete --topic $$t || true; \
	done

PARTITIONS ?= 8
kafka-create-topics:
	@for t in topic1 topic2 topic3 topic4; do \
		echo "creating $$t with $(PARTITIONS) partitions..."; \
		kubectl exec -n $(KAFKA_NS) $(KAFKA_POD) -- bin/kafka-topics.sh \
			--bootstrap-server localhost:9092 \
			--create --if-not-exists \
			--topic $$t \
			--partitions $(PARTITIONS) \
			--replication-factor 1; \
	done

kafka-describe-topics:
	@for t in topic1 topic2 topic3 topic4; do \
		echo "--- $$t ---"; \
		kubectl exec -n $(KAFKA_NS) $(KAFKA_POD) -- bin/kafka-topics.sh \
			--bootstrap-server localhost:9092 --describe --topic $$t; \
	done

reset:
	kubectl scale deploy/subscriber --replicas=0
	kubectl scale deploy/publisher --replicas=0
	-kubectl wait --for=delete pod -l app=publisher --timeout=30s
	-kubectl wait --for=delete pod -l app=subscriber --timeout=30s
	$(MAKE) redis-flush
	-kubectl exec -n $(KAFKA_NS) $(KAFKA_POD) -- bin/kafka-consumer-groups.sh \
		--bootstrap-server localhost:9092 --delete --group subscriber
	$(MAKE) kafka-delete-topics
	sleep 5
	$(MAKE) kafka-create-topics
	kubectl scale deploy/publisher --replicas=1
	@echo "==> publisher starting; wait for 'FINISHED publishing' then run: kubectl scale deploy/subscriber --replicas=1"

logs-pub:
	kubectl logs -f deploy/publisher -c publisher

logs-sub:
	kubectl logs -f deploy/subscriber -c subscriber

logs-sub-daprd:
	kubectl logs -f deploy/subscriber -c daprd

logs-pub-daprd:
	kubectl logs -f deploy/publisher -c daprd

logs-sub-daprd-prev:
	kubectl logs --previous deploy/subscriber -c daprd

rollout:
	kubectl rollout restart deploy/subscriber

ROLLOUT_INTERVAL ?= 120
rollout-loop:
	@while true; do \
		date; \
		kubectl rollout restart deploy/subscriber; \
		sleep $(ROLLOUT_INTERVAL); \
	done

reconcile:
	./reconcile.sh

reproduce: build push deploy
