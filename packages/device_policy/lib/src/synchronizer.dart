import 'journal.dart';
import 'transport.dart';
import 'dart:async';
import 'package:retry/retry.dart';

class ConfigurationSyncResult {
  final int pages, storedConfigurations, receiptsAcknowledged, cursor;
  final bool hasMore;
  const ConfigurationSyncResult(
      {required this.pages,
      required this.storedConfigurations,
      required this.receiptsAcknowledged,
      required this.cursor,
      required this.hasMore});
  bool get systemEnforced => false;
}

/// Hosts call this from foreground/background work or an authenticated notice.
/// It is single-flight and bounded; OS scheduling and boot delivery stay with
/// the native host. An unknown POST result leaves the original journal intact.
class DeviceConfigurationSynchronizer {
  final ConfigurationJournal journal;
  final DeviceConfigurationTransport transport;
  final int pageSize, maxPages;
  Future<ConfigurationSyncResult>? _running;
  bool _closed = false;
  static const _retry = RetryOptions(
      delayFactor: Duration(seconds: 1), maxDelay: Duration(seconds: 60));
  DeviceConfigurationSynchronizer(
      {required this.journal,
      required this.transport,
      this.pageSize = 10,
      this.maxPages = 5}) {
    if (pageSize < 1 || pageSize > 50 || maxPages < 1 || maxPages > 100) {
      throw ArgumentError('Invalid synchronization limits');
    }
  }
  Future<ConfigurationSyncResult> synchronize() {
    if (_closed) {
      return Future.error(const DeviceTransportFailure('CLIENT_CLOSED'));
    }
    if (_running != null) {
      return _running!;
    }
    final future = _perform();
    _running = future;
    unawaited(future.then<void>((_) {
      _running = null;
    }, onError: (Object error, StackTrace stack) {
      _running = null;
    }));
    return future;
  }

  void _ensureOpen() {
    if (_closed) {
      throw const DeviceTransportFailure('CLIENT_CLOSED');
    }
  }

  Future<int> _flush() async {
    var count = 0;
    for (final receipt in await journal.pendingReceipts()) {
      _ensureOpen();
      await transport.acknowledge(receipt);
      await journal.acknowledge(receipt.receiptId);
      count++;
    }
    return count;
  }

  Future<ConfigurationSyncResult> _perform() async {
    var acknowledgements = await _flush();
    var pages = 0, stored = 0;
    bool more = false;
    do {
      _ensureOpen();
      final after = await journal.cursor();
      final page = await transport.pull(after: after, limit: pageSize);
      _ensureOpen();
      await journal.acceptPage(page);
      pages++;
      stored += page.items.length;
      more = page.hasMore;
      acknowledgements += await _flush();
    } while (more && pages < maxPages);
    return ConfigurationSyncResult(
        pages: pages,
        storedConfigurations: stored,
        receiptsAcknowledged: acknowledgements,
        cursor: await journal.cursor(),
        hasMore: more);
  }

  /// A scheduling hint, not an in-process infinite retry loop. Authentication,
  /// protocol and receipt conflicts require recovery instead of blind retries.
  Duration? retryDelay(DeviceTransportFailure failure, int attempt) {
    if (attempt < 1 || attempt > 31) {
      throw ArgumentError('Invalid retry attempt');
    }
    if (!failure.retryable) {
      return null;
    }
    final delay = failure.retryAfter ?? _retry.delay(attempt);
    return delay < const Duration(seconds: 1)
        ? const Duration(seconds: 1)
        : delay;
  }

  void close() {
    _closed = true;
    transport.close();
  }
}
