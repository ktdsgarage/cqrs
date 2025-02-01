package com.telecom.cqrs.query.dto;

import io.swagger.v3.oas.annotations.media.Schema;
import lombok.Data;

/**
 * 요금제 조회 응답을 위한 DTO 클래스입니다.
 */
@Data
@Schema(description = "요금제 조회 응답")
public class UsageQueryResponse {
    @Schema(description = "사용자 ID", example = "user123")
    private String userId;
    
    @Schema(description = "요금제명", example = "5G 프리미엄")
    private String planName;
    
    @Schema(description = "데이터 제공량(GB)", example = "100")
    private int dataAllowance;
    
    @Schema(description = "데이터 사용량(GB)", example = "35")
    private Long dataUsage;
    
    @Schema(description = "통화 제공량(분)", example = "300")
    private int callMinutes;
    
    @Schema(description = "통화 사용량(분)", example = "120")
    private Long callUsage;
    
    @Schema(description = "문자 제공량(건)", example = "300")
    private int messageCount;
    
    @Schema(description = "문자 사용량(건)", example = "50")
    private Long messageUsage;
    
    @Schema(description = "월 요금(원)", example = "50000")
    private double monthlyFee;
}
