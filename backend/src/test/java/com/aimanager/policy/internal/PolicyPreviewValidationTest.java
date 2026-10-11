package com.aimanager.policy.internal;

import static org.assertj.core.api.Assertions.assertThat;

import jakarta.validation.Validation;
import jakarta.validation.Validator;
import jakarta.validation.ValidatorFactory;
import java.util.List;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

class PolicyPreviewValidationTest {
  private static final ValidatorFactory FACTORY = Validation.buildDefaultValidatorFactory();
  private static final Validator VALIDATOR = FACTORY.getValidator();
  private static final String DEVICE = "0c9b33b3-bb8d-4c60-85e7-95744a16e27e";
  private static final String GROUP = "5ad51910-02c8-42c4-b5e3-38c588471fce";

  @AfterAll
  static void closeValidatorFactory() {
    FACTORY.close();
  }

  @Test
  void canonicalDeviceIdPassesTheHttpRequestBoundary() {
    assertThat(VALIDATOR.validate(new PolicyController.Preview(List.of(DEVICE), null, null)))
        .isEmpty();
  }

  @Test
  void canonicalGroupAndDeviceIdsPassTheHttpRequestBoundary() {
    assertThat(VALIDATOR.validate(new PolicyController.Preview(List.of(DEVICE), GROUP, 0L)))
        .isEmpty();
  }

  @ParameterizedTest
  @ValueSource(strings = {"0c9b33b3-bb8d-4c60-95744a16e27e", "", "../devices", " 0c9b33b3-bb8d-4c60-85e7-95744a16e27e"})
  void malformedDeviceIdIsRejected(String id) {
    assertThat(VALIDATOR.validate(new PolicyController.Preview(List.of(id), null, null)))
        .anyMatch(violation -> violation.getPropertyPath().toString().startsWith("deviceIds"));
  }

  @ParameterizedTest
  @ValueSource(strings = {"5ad51910-02c8-42c4-38c588471fce", "", "../groups", " 5ad51910-02c8-42c4-b5e3-38c588471fce"})
  void malformedGroupIdIsRejected(String id) {
    assertThat(VALIDATOR.validate(new PolicyController.Preview(List.of(DEVICE), id, 0L)))
        .anyMatch(violation -> violation.getPropertyPath().toString().equals("groupId"));
  }
}
