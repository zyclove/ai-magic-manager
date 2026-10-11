package com.aimanager.retention.internal;

import com.aimanager.retention.ErasureLedger;
import java.lang.reflect.Method;
import java.util.concurrent.*;
import java.util.function.Supplier;
import org.aopalliance.intercept.MethodInterceptor;
import org.springframework.aop.framework.AopProxyUtils;
import org.springframework.aop.support.*;
import org.springframework.context.event.EventListener;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.AnnotatedElementUtils;
import org.springframework.scheduling.annotation.*;

class ErasureWorkAdvisor extends DefaultPointcutAdvisor {
  ErasureWorkAdvisor(Supplier<ErasureWorkScope> scope) {
    super(
        new StaticMethodMatcherPointcut() {
          @Override
          public boolean matches(Method method, Class<?> target) {
            if (!target.getName().startsWith("com.aimanager.")) return false;
            var specific = AopUtils.getMostSpecificMethod(method, target);
            return scheduled(specific)
                || AnnotatedElementUtils.hasAnnotation(specific, EventListener.class)
                || AnnotatedElementUtils.hasAnnotation(specific, Async.class)
                || AnnotatedElementUtils.hasAnnotation(target, Async.class);
          }
        },
        (MethodInterceptor)
            invocation -> {
              var method =
                  AopUtils.getMostSpecificMethod(
                      invocation.getMethod(),
                      AopProxyUtils.ultimateTargetClass(invocation.getThis()));
              boolean scheduled = scheduled(method);
              if (scheduled && method.getReturnType() != void.class)
                throw new IllegalStateException(
                    "Scheduled work must execute synchronously inside its permit");
              final ErasureLedger.WorkPermit permit;
              try {
                permit = scope.get().enter();
              } catch (ErasureLedger.Failure denied) {
                if (scheduled) return null;
                throw denied;
              }
              try (permit) {
                Object result = invocation.proceed();
                // Spring's async interceptor also awaits returned Future values. Keep admission
                // until
                // the actual work completes, including across executor interruption during
                // shutdown.
                if (result instanceof Future<?> future) {
                  boolean interrupted = false;
                  try {
                    while (true)
                      try {
                        future.get();
                        break;
                      } catch (InterruptedException wait) {
                        interrupted = true;
                      }
                  } catch (ExecutionException | CancellationException uncertain) {
                    // A timed-out, exceptionally completed, or cancelled Future does not prove
                    // that its producer stopped. Preserve admission until safe recovery proves it.
                    scope.get().completionUncertain();
                    throw new ErasureLedger.Failure("ERASURE_LEDGER_WORK_COMPLETION_UNKNOWN");
                  } finally {
                    if (interrupted) Thread.currentThread().interrupt();
                  }
                }
                return result;
              }
            });
    setOrder(Ordered.HIGHEST_PRECEDENCE + 50);
  }

  private static boolean scheduled(Method method) {
    return AnnotatedElementUtils.hasAnnotation(method, Scheduled.class)
        || AnnotatedElementUtils.hasAnnotation(method, Schedules.class);
  }
}
