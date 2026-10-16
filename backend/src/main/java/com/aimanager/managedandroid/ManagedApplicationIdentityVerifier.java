package com.aimanager.managedandroid;

import com.aimanager.shared.DomainException;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.DateTimeException;
import java.util.HashSet;
import java.util.Objects;
import java.util.Set;
import java.util.regex.Pattern;
import org.springframework.http.HttpStatus;

/**
 * 将提供方应用事实绑定到服务端捕获和重新加载的当前上下文。调用方必须在短事务中完成
 * 当前租户权限、合同、设备注册及有效绑定检查；本类不访问数据库，也不证明 Android 用户空间。
 * 所有输入只允许来自已授权的服务端记录及提供方连接器，不可由请求体直接绑定。
 */
public final class ManagedApplicationIdentityVerifier {
  private static final int MAX_SIGNERS = 8;
  private static final Pattern ID = Pattern.compile("[A-Za-z0-9_-]{1,128}");
  private static final Pattern SHA256 = Pattern.compile("[0-9a-f]{64}");
  private static final Pattern THUMBPRINT = Pattern.compile("[A-Za-z0-9_-]{43}");
  private static final Pattern PROVIDER = Pattern.compile("[A-Z][A-Z0-9_]{0,63}");
  private static final Pattern RESOURCE = Pattern.compile("[A-Za-z0-9_./:-]{1,512}");
  private static final Pattern REVISION = Pattern.compile("[A-Za-z0-9._-]{1,128}");
  private static final Pattern PACKAGE = Pattern.compile("[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)+");
  private static final Set<String> MANAGED_MODES = Set.of("DEVICE_OWNER", "PROFILE_OWNER");
  private final Clock clock;
  private final Duration maximumReportAge;
  private final Duration maximumReuseAge;
  private final Duration allowedClockSkew;

  public ManagedApplicationIdentityVerifier(
      Clock clock, Duration maximumReportAge, Duration maximumReuseAge, Duration allowedClockSkew) {
    this.clock = Objects.requireNonNull(clock);
    this.maximumReportAge = Objects.requireNonNull(maximumReportAge);
    this.maximumReuseAge = Objects.requireNonNull(maximumReuseAge);
    this.allowedClockSkew = Objects.requireNonNull(allowedClockSkew);
    if (maximumReportAge.isNegative() || maximumReportAge.isZero()
        || maximumReportAge.compareTo(Duration.ofHours(1)) > 0
        || maximumReuseAge.isNegative() || maximumReuseAge.isZero()
        || maximumReuseAge.compareTo(Duration.ofMinutes(5)) > 0
        || allowedClockSkew.isNegative() || allowedClockSkew.compareTo(Duration.ofSeconds(30)) > 0) {
      throw new IllegalArgumentException("Invalid managed application freshness configuration");
    }
  }

  /** 捕获与当前上下文必须一致；有效期取报告硬期限与本次获取缓存期限的较早者。 */
  public Verified verify(
      Context captured, Context current, ManagedApplicationReport report, Instant retrievedAt) {
    Instant now = clock.instant();
    validateContext(captured, now);
    validateContext(current, now);
    if (!captured.equals(current)) {
      throw new DomainException(HttpStatus.CONFLICT, "MANAGED_APPLICATION_CONTEXT_CHANGED");
    }
    if (report == null) throw rejected("MANAGED_APPLICATION_REPORT_MISSING");
    if (!current.scope().providerDeviceName().equals(report.deviceName())
        || !current.packageName().equals(report.packageName())
        || !current.managementMode().equals(report.managementMode())) {
      throw rejected("MANAGED_APPLICATION_REPORT_INVALID");
    }
    if (!"INSTALLED".equals(report.applicationState())) {
      throw rejected("MANAGED_APPLICATION_INSTALLATION_NOT_CONFIRMED");
    }
    var signers = report.signingCertificateSha256();
    if (signers.isEmpty() || signers.size() > MAX_SIGNERS
        || signers.stream().anyMatch(value -> !matches(SHA256, value))
        || new HashSet<>(signers).size() != signers.size()
        || !current.trustedSigningCertificates().containsAll(signers)) {
      throw rejected("MANAGED_APPLICATION_SIGNER_UNTRUSTED");
    }
    if (retrievedAt == null || retrievedAt.isAfter(now) || report.deviceReportedAt() == null) {
      throw rejected("MANAGED_APPLICATION_REPORT_INVALID");
    }
    try {
      Instant reportedAt = Instant.parse(report.deviceReportedAt());
      if (reportedAt.isAfter(now.plus(allowedClockSkew))
          || reportedAt.isAfter(retrievedAt.plus(allowedClockSkew))) {
        throw rejected("MANAGED_APPLICATION_REPORT_INVALID");
      }
      if (reportedAt.isBefore(current.evidenceNotBefore())
          || retrievedAt.isBefore(current.evidenceNotBefore())) {
        throw rejected("MANAGED_APPLICATION_REPORT_STALE");
      }
      Instant reportDeadline = reportedAt.plus(maximumReportAge);
      Instant reuseDeadline = retrievedAt.plus(maximumReuseAge);
      Instant expiresAt = reportDeadline.isBefore(reuseDeadline) ? reportDeadline : reuseDeadline;
      // 精确到期即拒绝；相同报告重新读取只刷新缓存，不能突破报告硬期限。
      if (!now.isBefore(expiresAt)) throw rejected("MANAGED_APPLICATION_REPORT_STALE");
      return new Verified(current, Set.copyOf(signers), reportedAt, retrievedAt, expiresAt,
          ProfileScope.UNKNOWN);
    } catch (DateTimeException | ArithmeticException malformed) {
      // 不携带原始时间字段或底层解析异常。
      throw rejected("MANAGED_APPLICATION_REPORT_INVALID");
    }
  }

  private static void validateContext(Context context, Instant now) {
    if (context == null || context.scope() == null || !context.active()
        || !matches(ID, context.applicationId())
        || !matches(SHA256, context.definitionRevision())
        || context.packageName() == null || context.packageName().length() > 255
        || !matches(PACKAGE, context.packageName())
        || context.managementMode() == null || !MANAGED_MODES.contains(context.managementMode())
        || context.evidenceNotBefore() == null || context.evidenceNotBefore().isBefore(Instant.EPOCH)
        || context.evidenceNotBefore().isAfter(now)
        || context.trustedSigningCertificates().isEmpty()
        || context.trustedSigningCertificates().size() > MAX_SIGNERS
        || context.trustedSigningCertificates().stream().anyMatch(value -> !matches(SHA256, value))) {
      throw rejected("MANAGED_APPLICATION_CONTEXT_INVALID");
    }
    Scope scope = context.scope();
    if (!matches(ID, scope.tenantId()) || !matches(ID, scope.deviceId())
        || !matches(ID, scope.registrationId()) || !matches(THUMBPRINT, scope.keyThumbprint())
        || !matches(ID, scope.bindingId()) || scope.bindingVersion() < 1
        || !matches(PROVIDER, scope.provider()) || !matches(RESOURCE, scope.providerDeviceName())
        || scope.enterpriseBindingVersion() < 1 || !matches(REVISION, scope.connectorRevision())) {
      throw rejected("MANAGED_APPLICATION_CONTEXT_INVALID");
    }
  }

  private static boolean matches(Pattern pattern, String value) {
    return value != null && pattern.matcher(value).matches();
  }

  private static DomainException rejected(String code) {
    return new DomainException(HttpStatus.UNPROCESSABLE_ENTITY, code);
  }

  /** 包含会使证据失效的设备、注册、绑定及连接器代次，不包含管理员身份。 */
  public record Scope(
      String tenantId,
      String deviceId,
      String registrationId,
      String keyThumbprint,
      String bindingId,
      long bindingVersion,
      String provider,
      String providerDeviceName,
      long enterpriseBindingVersion,
      String connectorRevision) {
    @Override
    public String toString() { return "ManagedApplicationScope[REDACTED]"; }
  }

  /**
   * definitionRevision 是身份定义的稳定摘要；evidenceNotBefore 是注册、绑定及身份定义生效时间
   * 的最大值。active 只能由当前有效记录推导，不接受客户端声明；授权仍由调用方完成。
   */
  public record Context(
      Scope scope,
      String applicationId,
      String definitionRevision,
      String packageName,
      Set<String> trustedSigningCertificates,
      String managementMode,
      Instant evidenceNotBefore,
      boolean active) {
    public Context {
      trustedSigningCertificates = trustedSigningCertificates == null
          ? Set.of() : Set.copyOf(trustedSigningCertificates);
    }
    @Override
    public String toString() { return "ManagedApplicationContext[REDACTED]"; }
  }

  /** 本地 PRIMARY/WORK/SECONDARY 映射需要独立证据；应用报告本身没有该字段。 */
  public enum ProfileScope { UNKNOWN }

  /** 仅用于服务端后续持久化和再次校验；不得直接解释为执行能力或已应用回执。 */
  public record Verified(
      Context context,
      Set<String> signingCertificates,
      Instant reportedAt,
      Instant retrievedAt,
      Instant expiresAt,
      ProfileScope profileScope) {
    public Verified { signingCertificates = Set.copyOf(signingCertificates); }
    @Override
    public String toString() { return "ManagedApplicationIdentity[REDACTED]"; }
  }
}
