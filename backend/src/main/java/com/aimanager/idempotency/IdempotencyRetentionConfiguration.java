package com.aimanager.idempotency;

import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Configuration;

/** 使用既有 Spring Boot 配置绑定，不增加外部配置客户端或独立调度框架。 */
@Configuration(proxyBeanMethods = false)
@EnableConfigurationProperties(IdempotencyRetentionSettings.class)
class IdempotencyRetentionConfiguration {}
