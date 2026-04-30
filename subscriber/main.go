package main

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"os/signal"
	"strconv"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/dapr/go-sdk/service/common"
	daprd "github.com/dapr/go-sdk/service/http"
	"github.com/redis/go-redis/v9"
)

const pubsubName = "kafka-pubsub"

var topics = []string{"topic1", "topic2", "topic3", "topic4"}

type msg struct {
	Seq   int64  `json:"seq"`
	Topic string `json:"topic"`
	Ts    string `json:"ts"`
}

func extractSeq(data any) int64 {
	b, err := json.Marshal(data)
	if err != nil {
		return -1
	}
	var m msg
	if err := json.Unmarshal(b, &m); err != nil {
		return -1
	}
	return m.Seq
}

func setKey(topic string) string { return "set:" + topic }

func main() {
	port := os.Getenv("APP_PORT")
	if port == "" {
		port = "6001"
	}

	processDelay := 100 * time.Millisecond
	if v := os.Getenv("PROCESS_DELAY_MS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			processDelay = time.Duration(n) * time.Millisecond
		}
	}

	redisAddr := os.Getenv("REDIS_ADDR")
	if redisAddr == "" {
		redisAddr = "redis:6379"
	}

	rdb := redis.NewClient(&redis.Options{Addr: redisAddr})
	defer rdb.Close()

	pingCtx, pingCancel := context.WithTimeout(context.Background(), 10*time.Second)
	if err := rdb.Ping(pingCtx).Err(); err != nil {
		pingCancel()
		log.Fatalf("redis ping: %v", err)
	}
	pingCancel()

	s := daprd.NewService(":" + port)

	var processed atomic.Int64
	var shuttingDown atomic.Bool
	var processedAtShutdown atomic.Int64
	for _, t := range topics {
		topic := t
		sub := &common.Subscription{
			PubsubName: pubsubName,
			Topic:      topic,
			Route:      "/" + topic,
		}
		if err := s.AddTopicEventHandler(sub, func(ctx context.Context, e *common.TopicEvent) (retry bool, err error) {
			seq := extractSeq(e.Data)
			n := processed.Add(1)
			if n <= 4 || n%500 == 0 {
				log.Printf("debug topic=%s seq=%d data_type=%T data=%v", topic, seq, e.Data, e.Data)
			}
			select {
			case <-time.After(processDelay):
			case <-ctx.Done():
				log.Printf("abandoned topic=%s seq=%d ctx=%v", topic, seq, ctx.Err())
				return true, ctx.Err()
			}
			removed, err := rdb.SRem(ctx, setKey(topic), seq).Result()
			if err != nil {
				log.Printf("redis SREM error topic=%s seq=%d err=%v", topic, seq, err)
				return true, err
			}
			if n <= 4 || n%500 == 0 {
				log.Printf("debug SREM topic=%s seq=%d removed=%d", topic, seq, removed)
			}
			return false, nil
		}); err != nil {
			log.Fatalf("add handler topic=%s: %v", topic, err)
		}
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	go func() {
		<-ctx.Done()
		atShutdown := processed.Load()
		processedAtShutdown.Store(atShutdown)
		shuttingDown.Store(true)
		log.Printf("shutdown signal received, processed=%d — keeping HTTP server up for daprd drain (kubelet will SIGKILL at terminationGracePeriodSeconds)", atShutdown)
		// Intentionally do NOT call s.GracefulStop() here.
		// daprd needs to deliver in-flight messages back to us during its
		// block-shutdown-duration window; closing the HTTP server early would
		// cause those messages to be abandoned. kubelet ends the process cleanly
		// via SIGKILL when terminationGracePeriodSeconds expires.
	}()

	// Periodic counter ticker. Intentionally NOT gated on ctx.Done — we want
	// to keep printing through the drain window so we can see whether daprd
	// is delivering buffered messages to us during its block-shutdown-duration
	// after SIGTERM. The ticker exits when the process is SIGKILL'd.
	go func() {
		t := time.NewTicker(1 * time.Second)
		defer t.Stop()
		for range t.C {
			n := processed.Load()
			if shuttingDown.Load() {
				log.Printf("draining: processed=%d (delta-since-SIGTERM=%d)",
					n, n-processedAtShutdown.Load())
			} else {
				log.Printf("processed=%d", n)
			}
		}
	}()

	log.Printf("subscriber started: port=%s pubsub=%s topics=%v delay=%s redis=%s",
		port, pubsubName, topics, processDelay, redisAddr)
	if err := s.Start(); err != nil {
		log.Fatalf("service: %v", err)
	}
}
