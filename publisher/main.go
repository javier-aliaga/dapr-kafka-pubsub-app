package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	dapr "github.com/dapr/go-sdk/client"
	"github.com/redis/go-redis/v9"
)

const pubsubName = "kafka-pubsub"

var topics = []string{"topic1", "topic2", "topic3", "topic4"}

func setKey(topic string) string { return "set:" + topic }

func main() {
	totalPerTopic := 50_000
	if v := os.Getenv("TOTAL_PER_TOPIC"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			totalPerTopic = n
		}
	}

	workers := 8
	if v := os.Getenv("WORKERS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			workers = n
		}
	}

	intervalMs := 0
	if v := os.Getenv("PUBLISH_INTERVAL_MS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			intervalMs = n
		}
	}

	redisAddr := os.Getenv("REDIS_ADDR")
	if redisAddr == "" {
		redisAddr = "redis:6379"
	}

	rdb := redis.NewClient(&redis.Options{Addr: redisAddr, PoolSize: workers * 2})
	defer rdb.Close()

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	if err := rdb.Ping(ctx).Err(); err != nil {
		log.Fatalf("redis ping: %v", err)
	}
	for _, t := range topics {
		if err := rdb.Del(ctx, setKey(t)).Err(); err != nil {
			log.Fatalf("redis del %s: %v", setKey(t), err)
		}
	}

	c, err := dapr.NewClient()
	if err != nil {
		log.Fatalf("dapr client: %v", err)
	}
	defer c.Close()

	target := int64(totalPerTopic * len(topics))
	log.Printf("publisher started: pubsub=%s topics=%v total_per_topic=%d total=%d workers=%d interval=%dms redis=%s",
		pubsubName, topics, totalPerTopic, target, workers, intervalMs, redisAddr)

	var seq atomic.Int64
	var sent atomic.Int64
	start := time.Now()

	go func() {
		t := time.NewTicker(2 * time.Second)
		defer t.Stop()
		var last int64
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				cur := sent.Load()
				rate := (cur - last) / 2
				last = cur
				log.Printf("progress sent=%d/%d rate=%d/s elapsed=%s", cur, target, rate, time.Since(start).Round(time.Millisecond))
			}
		}
	}()

	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				if ctx.Err() != nil {
					return
				}
				n := seq.Add(1)
				if n > target {
					return
				}
				topic := topics[int(n)%len(topics)]
				key := setKey(topic)
				if err := rdb.SAdd(ctx, key, n).Err(); err != nil {
					log.Printf("redis SADD error topic=%s seq=%d err=%v", topic, n, err)
					continue
				}
				payload := map[string]any{
					"seq":   n,
					"topic": topic,
					"ts":    time.Now().UTC().Format(time.RFC3339Nano),
				}
				if err := c.PublishEvent(ctx, pubsubName, topic, payload); err != nil {
					log.Printf("publish error topic=%s seq=%d err=%v", topic, n, err)
					_ = rdb.SRem(ctx, key, n).Err()
					continue
				}
				sent.Add(1)
				if intervalMs > 0 {
					time.Sleep(time.Duration(intervalMs) * time.Millisecond)
				}
			}
		}()
	}
	wg.Wait()

	final := sent.Load()
	log.Printf("FINISHED publishing %d messages in %s — idling, waiting for shutdown signal",
		final, time.Since(start).Round(time.Millisecond))
	for _, t := range topics {
		n, _ := rdb.SCard(ctx, setKey(t)).Result()
		log.Printf("redis %s = %d (expected %d if subscriber hasn't started)", setKey(t), n, totalPerTopic)
	}
	<-ctx.Done()
	log.Printf("shutdown signal received")
}
