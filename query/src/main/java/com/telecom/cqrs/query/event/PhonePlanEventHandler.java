package com.telecom.cqrs.query.event;

import com.azure.messaging.eventhubs.EventProcessorClient;
import com.azure.messaging.eventhubs.models.ErrorContext;
import com.azure.messaging.eventhubs.models.EventContext;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.telecom.cqrs.common.event.PhonePlanEvent;
import com.telecom.cqrs.query.domain.UsageView;
import com.telecom.cqrs.query.exception.EventProcessingException;
import com.telecom.cqrs.query.repository.UsageViewRepository;
import lombok.extern.slf4j.Slf4j;
import org.springframework.retry.support.RetryTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.retry.annotation.Retryable;
import org.springframework.retry.annotation.Backoff;

import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Consumer;

@Slf4j
@Service
public class PhonePlanEventHandler implements Consumer<EventContext> {
    private final UsageViewRepository usageViewRepository;
    private final ObjectMapper objectMapper;
    private final RetryTemplate retryTemplate;
    private final AtomicLong eventsProcessed = new AtomicLong(0);
    private final AtomicLong eventErrors = new AtomicLong(0);
    private EventProcessorClient eventProcessorClient;

    public PhonePlanEventHandler(
            UsageViewRepository usageViewRepository,
            ObjectMapper objectMapper,
            RetryTemplate retryTemplate) {
        this.usageViewRepository = usageViewRepository;
        this.objectMapper = objectMapper;
        this.retryTemplate = retryTemplate;
    }

    public void setEventProcessorClient(EventProcessorClient client) {
        log.info("Setting Plan Event Processor Client");
        this.eventProcessorClient = client;
        startEventProcessing();
    }

    @Retryable(maxAttempts = 3, backoff = @Backoff(delay = 1000, multiplier = 2))
    public void startEventProcessing() {
        if (eventProcessorClient != null) {
            log.info("Starting Plan Event Processor...");
            try {
                eventProcessorClient.start();
                log.info("Plan Event Processor started successfully");
            } catch (Exception e) {
                log.error("Failed to start Plan Event Processor: {}", e.getMessage(), e);
                throw new RuntimeException("Failed to start event processor", e);
            }
        } else {
            log.warn("Plan Event Processor Client is not set");
        }
    }

    @Override
    @Transactional
    public void accept(EventContext eventContext) {
        String eventData = eventContext.getEventData().getBodyAsString();
        String partitionId = eventContext.getPartitionContext().getPartitionId();

        log.info("***** Received plan event: {}", eventData);

        try {
            log.debug("Processing plan event: partition={}, offset={}, data={}",
                    partitionId,
                    eventContext.getEventData().getSequenceNumber(),
                    eventData);

            PhonePlanEvent event = parseEvent(eventData);
            if (event != null) {
                processUserEvent(event);
                eventsProcessed.incrementAndGet();
                eventContext.updateCheckpoint();
                log.debug("Plan event processed successfully: userId={}", event.getUserId());
            }
        } catch (Exception e) {
            log.error("Failed to process plan event: partition={}, data={}, error={}",
                    partitionId, eventData, e.getMessage(), e);
            eventErrors.incrementAndGet();
        }
    }

    private PhonePlanEvent parseEvent(String eventData) {
        try {
            return objectMapper.readValue(eventData, PhonePlanEvent.class);
        } catch (Exception e) {
            log.error("Error parsing plan event: {}", e.getMessage(), e);
            return null;
        }
    }

    private void processUserEvent(PhonePlanEvent event) {
        try {
            retryTemplate.execute(context -> {
                UsageView view = getOrCreatePhonePlanView(event.getUserId());
                updateViewFromEvent(view, event);
                UsageView savedView = usageViewRepository.save(view);
                log.info("***** Plan event processed result - userId: {}, planName: {}, dataAllowance: {}, callMinutes: {}, messageCount: {}",
                        savedView.getUserId(), savedView.getPlanName(), savedView.getDataAllowance(),
                        savedView.getCallMinutes(), savedView.getMessageCount());  // 추가
                return null;
            });
        } catch (Exception e) {
            log.error("Error processing plan event for userId={}: {}",
                    event.getUserId(), e.getMessage(), e);
            throw new EventProcessingException("Failed to process plan event", e);
        }
    }

    private UsageView getOrCreatePhonePlanView(String userId) {
        UsageView view = usageViewRepository.findByUserId(userId);
        if (view == null) {
            view = new UsageView();
            view.setUserId(userId);
            log.debug("Creating new UsageView for userId={}", userId);
        }
        return view;
    }

    private void updateViewFromEvent(UsageView view, PhonePlanEvent event) {
        view.setPlanName(event.getPlanName());
        view.setDataAllowance(event.getDataAllowance());
        view.setCallMinutes(event.getCallMinutes());
        view.setMessageCount(event.getMessageCount());
        view.setMonthlyFee(event.getMonthlyFee());
        view.setStatus(event.getStatus());
    }

    public void processError(ErrorContext errorContext) {
        log.error("Error in plan event processor: {}, {}",
                errorContext.getThrowable().getMessage(),
                errorContext.getPartitionContext().getPartitionId(),
                errorContext.getThrowable());
        eventErrors.incrementAndGet();
    }

    public long getProcessedEventCount() {
        return eventsProcessed.get();
    }

    public long getErrorCount() {
        return eventErrors.get();
    }

    public void cleanup() {
        if (eventProcessorClient != null) {
            try {
                log.info("Stopping Plan Event Processor...");
                eventProcessorClient.stop();
                log.info("Plan Event Processor stopped");
            } catch (Exception e) {
                log.error("Error stopping Plan Event Processor: {}", e.getMessage(), e);
            }
        }
    }
}