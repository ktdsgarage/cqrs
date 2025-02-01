package com.telecom.cqrs.query.mapper;

import com.telecom.cqrs.query.domain.UsageView;
import com.telecom.cqrs.query.dto.UsageQueryResponse;
import org.springframework.stereotype.Component;

/**
 * MongoDB 도큐먼트와 DTO 간의 변환을 담당하는 매퍼입니다.
 */
@Component
public class UsageMapper {

    /**
     * UsageView 엔티티를 UsageQueryResponse DTO로 변환합니다.
     */
    public UsageQueryResponse toDto(UsageView view) {
        if (view == null) {
            return null;
        }

        UsageQueryResponse response = new UsageQueryResponse();
        response.setUserId(view.getUserId());
        response.setPlanName(view.getPlanName());
        response.setDataAllowance(view.getDataAllowance());
        response.setDataUsage(view.getDataUsage());
        response.setCallMinutes(view.getCallMinutes());
        response.setCallUsage(view.getCallUsage());
        response.setMessageCount(view.getMessageCount());
        response.setMessageUsage(view.getMessageUsage());
        response.setMonthlyFee(view.getMonthlyFee());

        return response;
    }
}