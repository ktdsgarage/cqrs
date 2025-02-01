package com.telecom.cqrs.query.domain;

import lombok.Data;
import org.springframework.data.annotation.Id;
import org.springframework.data.mongodb.core.mapping.Document;

/**
 * 요금제 조회를 위한 도큐먼트 클래스입니다.
 * Read DB(MongoDB)에 저장됩니다.
 */
@Document(collection = "phone_plan_views")
@Data
public class UsageView {
    @Id
    private String id;
    
    private String userId;
    private String planName;
    private int dataAllowance;
    private int callMinutes;
    private int messageCount;
    private double monthlyFee;
    private String status;
    private Long dataUsage;
    private Long callUsage;
    private Long messageUsage;
}
