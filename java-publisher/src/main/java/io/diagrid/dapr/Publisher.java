package io.diagrid.dapr;

import io.dapr.client.DaprClient;
import io.dapr.client.DaprClientBuilder;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;

@Component
public class Publisher {

  private static final String PUBSUB_NAME = "kafka-pubsub";
  private static final String TOPIC_NAME = "topicBulkSub";

  private final String runHash;
  private final int firstBatch;
  private final int sleepMs;
  private final int secondBatch;

  public Publisher() {
    this.runHash = randomHash(5);
    this.firstBatch = intEnv("FIRST_BATCH", 18);
    this.sleepMs = intEnv("SLEEP_MS", 5000);
    this.secondBatch = intEnv("SECOND_BATCH", 10);
  }

  @EventListener(ApplicationReadyEvent.class)
  public void run() throws Exception {
    System.out.printf("Run hash: %s%n", runHash);
    try (DaprClient client = new DaprClientBuilder().build()) {
      sendBatch(client, firstBatch, runHash + "-a");
      System.out.printf("Sleeping %dms before second batch%n", sleepMs);
      Thread.sleep(sleepMs);
      sendBatch(client, secondBatch, runHash + "-b");
      System.out.printf("FINISHED publishing %d messages to %s%n",
          firstBatch + secondBatch, TOPIC_NAME);
    }
  }

  private static void sendBatch(DaprClient client, int n, String prefix) {
    for (int i = 0; i < n; i++) {
      String message = String.format("This is message %s-#%d on topic %s", prefix, i, TOPIC_NAME);
      client.publishEvent(PUBSUB_NAME, TOPIC_NAME, message).block();
      System.out.printf("Published: '%s'%n", message);
    }
  }

  private static String randomHash(int length) {
    String chars = "abcdefghijklmnopqrstuvwxyz0123456789";
    java.util.Random r = new java.util.Random();
    StringBuilder sb = new StringBuilder(length);
    for (int i = 0; i < length; i++) sb.append(chars.charAt(r.nextInt(chars.length())));
    return sb.toString();
  }

  private static int intEnv(String name, int fallback) {
    String v = System.getenv(name);
    if (v == null || v.isBlank()) return fallback;
    try { return Integer.parseInt(v); } catch (NumberFormatException e) { return fallback; }
  }
}
