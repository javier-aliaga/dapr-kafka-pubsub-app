package io.diagrid.dapr;

import io.dapr.Topic;
import io.dapr.client.domain.BulkSubscribeAppResponse;
import io.dapr.client.domain.BulkSubscribeAppResponseEntry;
import io.dapr.client.domain.BulkSubscribeAppResponseStatus;
import io.dapr.client.domain.BulkSubscribeMessage;
import io.dapr.client.domain.BulkSubscribeMessageEntry;
import io.dapr.client.domain.CloudEvent;
import io.dapr.springboot.annotations.BulkSubscribe;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;
import reactor.core.publisher.Mono;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

@RestController
public class SubscriberController {

  private static final String PUBSUB_NAME = "kafka-pubsub";
  private static final String TOPIC_NAME = "topicBulkSub";

  private static final List<BulkSubscribeAppResponse> responses =
      Collections.synchronizedList(new ArrayList<>());

  @GetMapping(path = "/messages/{topic}")
  public List<BulkSubscribeAppResponse> getMessages(@PathVariable("topic") String topic) {
    if (!TOPIC_NAME.equals(topic)) {
      return Collections.emptyList();
    }
    return new ArrayList<>(responses);
  }

  @BulkSubscribe(maxMessagesCount = 10, maxAwaitDurationMs = 10000)
  @Topic(name = TOPIC_NAME, pubsubName = PUBSUB_NAME)
  @PostMapping(path = "/routeBulkSub")
  public Mono<BulkSubscribeAppResponse> handleMessageBulk(
      @RequestBody(required = false) BulkSubscribeMessage<CloudEvent<String>> bulkMessage) {
    return Mono.fromCallable(() -> {
      if (bulkMessage == null || bulkMessage.getEntries() == null || bulkMessage.getEntries().isEmpty()) {
        BulkSubscribeAppResponse empty = new BulkSubscribeAppResponse(new ArrayList<>());
        responses.add(empty);
        return empty;
      }
      System.out.printf("###### Received bulk batch of %d on topic '%s'%n",
          bulkMessage.getEntries().size(), bulkMessage.getTopic());
      List<BulkSubscribeAppResponseEntry> entries = new ArrayList<>();
      for (BulkSubscribeMessageEntry<?> entry : bulkMessage.getEntries()) {
        try {
          @SuppressWarnings("unchecked")
          CloudEvent<String> ce = (CloudEvent<String>) entry.getEvent();
          System.out.printf("  entryId=%s data=%s%n", entry.getEntryId(), ce.getData());
          entries.add(new BulkSubscribeAppResponseEntry(entry.getEntryId(), BulkSubscribeAppResponseStatus.SUCCESS));
        } catch (Exception e) {
          entries.add(new BulkSubscribeAppResponseEntry(entry.getEntryId(), BulkSubscribeAppResponseStatus.RETRY));
        }
      }
      BulkSubscribeAppResponse response = new BulkSubscribeAppResponse(entries);
      responses.add(response);
      return response;
    });
  }
}
