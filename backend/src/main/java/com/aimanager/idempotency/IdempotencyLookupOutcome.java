package com.aimanager.idempotency;

import com.aimanager.shared.DomainException;
import java.util.Objects;
import java.util.function.Function;
import java.util.function.Supplier;
import org.springframework.http.HttpStatus;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * 原结果查询的内部结果，不是 HTTP 成功响应。
 *
 * <p>事务内仅映射已找到的结果；到期事实随最外层事务提交后，由 HTTP 适配层转换为 410。
 * 不在事务内抛出到期领域异常，避免该异常回滚刚保存的不可逆到期标记。
 *
 * @param <T> 当前领域允许返回的结果类型
 */
public final class IdempotencyLookupOutcome<T> {
  private enum State { FOUND, MISSING, EXPIRED }

  private final State state;
  private final T value;

  private IdempotencyLookupOutcome(State state, T value) {
    this.state = Objects.requireNonNull(state, "Lookup state is required");
    if ((state == State.FOUND) != (value != null)) {
      throw new IllegalArgumentException("Invalid lookup outcome");
    }
    this.value = value;
  }

  /** 已找到并验证的原结果；不允许以 null 冒充有效结果。 */
  public static <T> IdempotencyLookupOutcome<T> found(T value) {
    return new IdempotencyLookupOutcome<>(State.FOUND, Objects.requireNonNull(value));
  }

  /** 没有该原键的已提交记录；这不证明业务从未执行。 */
  public static <T> IdempotencyLookupOutcome<T> missing() {
    return new IdempotencyLookupOutcome<>(State.MISSING, null);
  }

  /** 结果已到期；该状态必须随调用者事务提交，不能按未找到或未执行处理。 */
  public static <T> IdempotencyLookupOutcome<T> expired() {
    return new IdempotencyLookupOutcome<>(State.EXPIRED, null);
  }

  /** 仅对找到的结果执行领域映射；缺失及到期不会调用映射函数。 */
  public <R> IdempotencyLookupOutcome<R> map(Function<? super T, ? extends R> mapper) {
    Objects.requireNonNull(mapper, "Lookup mapper is required");
    return switch (state) {
      case FOUND -> found(mapper.apply(value));
      case MISSING -> missing();
      case EXPIRED -> expired();
    };
  }

  /** 保留现有领域的缺失拒绝；到期结果继续传出事务，不能在这里转换为异常。 */
  public IdempotencyLookupOutcome<T> requirePresent(
      Supplier<? extends RuntimeException> missingFailure) {
    Objects.requireNonNull(missingFailure, "Missing-result failure is required");
    if (state == State.MISSING) {
      throw missingFailure.get();
    }
    return this;
  }

  /** 领域已处理缺失结果后，HTTP 适配层在事务外保留原成功 DTO。 */
  public T toHttpResult() {
    return orElseThrow(() -> new IllegalStateException("Missing lookup outcome escaped its domain"));
  }

  /** 在最外层事务已经结束的 HTTP 适配层提取结果，保留原领域的缺失错误。 */
  public T orElseThrow(Supplier<? extends RuntimeException> missingFailure) {
    Objects.requireNonNull(missingFailure, "Missing-result failure is required");
    if (TransactionSynchronizationManager.isActualTransactionActive()
        || TransactionSynchronizationManager.isSynchronizationActive()) {
      throw new IllegalStateException("Lookup outcome must leave the outermost transaction first");
    }
    return switch (state) {
      case FOUND -> value;
      case MISSING -> throw missingFailure.get();
      case EXPIRED -> throw new DomainException(HttpStatus.GONE, "IDEMPOTENCY_RESULT_EXPIRED");
    };
  }

  /** 仅输出状态，不将儿童资料或原响应写入诊断。 */
  @Override
  public String toString() {
    return "IdempotencyLookupOutcome[" + state + "]";
  }
}
