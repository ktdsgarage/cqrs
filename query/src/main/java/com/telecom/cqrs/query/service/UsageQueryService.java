package com.telecom.cqrs.query.service;

import com.telecom.cqrs.query.domain.UsageView;
import com.telecom.cqrs.query.dto.UsageQueryResponse;
import com.telecom.cqrs.query.mapper.UsageMapper;
import com.telecom.cqrs.query.repository.UsageViewRepository;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;

/**
 * 요금제 조회 기능을 제공하는 서비스입니다.
 */
@Slf4j
@Service
@RequiredArgsConstructor
public class UsageQueryService {
    private final UsageViewRepository usageViewRepository;
    private final UsageMapper usageMapper;

    /**
     * 사용자의 요금제 정보를 조회합니다.
     * @param userId 조회할 사용자 ID
     * @return 요금제 정보. 없으면 null을 반환
     */
    public UsageQueryResponse getUsage(String userId) {
        log.debug("Querying usage for user: {}", userId);
        UsageView view = usageViewRepository.findByUserId(userId);
        return usageMapper.toDto(view);
    }
}