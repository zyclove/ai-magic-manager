import 'journal.dart';
import 'transport.dart';
import 'dart:async';
import 'package:retry/retry.dart';
import 'models.dart';
import 'receipt.dart';
import 'page.dart';

class AccessSyncIssue {
  final String requestId, code;
  final int? status;
  final Duration? retryAfter;
  final bool retryable, outcomeUnknown;
  const AccessSyncIssue(this.requestId, this.code,
      {this.status,
      this.retryAfter,
      this.retryable = false,
      this.outcomeUnknown = false});
}

class AccessSyncResult {
  final int pages, documentsStored, receiptsAcknowledged, retriesCreated;
  final bool hasMore;
  final int pendingReceipts;
  final List<AccessSyncIssue> issues;
  const AccessSyncResult(
      {required this.pages,
      required this.documentsStored,
      required this.receiptsAcknowledged,
      required this.retriesCreated,
      required this.hasMore,
      this.pendingReceipts = 0,
      required this.issues});
  bool get systemEnforced => false;
}

class DeviceAccessSynchronizer {
  final AccessWindowJournal journal;
  final DeviceAccessTransport transport;
  final int pageSize, maxPages, maxReceiptPosts;
  Future<AccessSyncResult>? _running;
  bool _closed = false;
  static const _retry = RetryOptions(
      delayFactor: Duration(seconds: 1), maxDelay: Duration(minutes: 1));
  DeviceAccessSynchronizer(
      {required this.journal,
      required this.transport,
      this.pageSize = 10,
      this.maxPages = 5,
      this.maxReceiptPosts = 128}) {
    if (pageSize < 1 ||
        pageSize > 100 ||
        maxPages < 1 ||
        maxPages > 100 ||
        maxReceiptPosts < 1 ||
        maxReceiptPosts > 1024) {
      throw ArgumentError('Invalid access synchronization limits');
    }
  }
  void _open() {
    if (_closed) throw const AccessTransportFailure('CLIENT_CLOSED');
  }

  bool _fatal(AccessTransportFailure error) =>
      error.status == 401 ||
      error.status == 403 ||
      {
        'CLIENT_CLOSED',
        'DEVICE_CREDENTIAL_UNAVAILABLE',
        'CREDENTIAL_READ_FAILED',
        'ACCESS_TARGET_CHANGED'
      }.contains(error.code);
  Future<AccessSyncResult> synchronize() {
    if (_closed) {
      return Future.error(const AccessTransportFailure('CLIENT_CLOSED'));
    }
    if (_running != null) return _running!;
    final future = _perform();
    _running = future;
    unawaited(future.then<void>((_) {
      _running = null;
    }, onError: (Object error, StackTrace stack) {
      _running = null;
    }));
    return future;
  }

  Future<AccessSyncResult> _perform() async {
    final issues = <AccessSyncIssue>[];
    final issueKeys = <String>{};
    final attempted = <String>{};
    final confirmed = <String, AccessReceiptAcknowledgement>{};
    int posts = 0, acknowledged = 0, stored = 0, pages = 0, retried = 0;
    bool postsAvailable = true;
    void issue(String requestId, String code,
        {AccessTransportFailure? transportError}) {
      if (issueKeys.add('$requestId:$code')) {
        issues.add(AccessSyncIssue(requestId, code,
            status: transportError?.status,
            retryAfter: transportError?.retryAfter,
            retryable: transportError?.retryable ?? false,
            outcomeUnknown: transportError?.outcomeUnknown ?? false));
      }
    }

    Future<void> post(AccessReceipt receipt) async {
      _open();
      final known = confirmed[receipt.key];
      if (known != null) {
        await journal.acknowledge(known);
        return;
      }
      if (!postsAvailable ||
          posts >= maxReceiptPosts ||
          !attempted.add(receipt.key)) return;
      posts++;
      try {
        final ack = await transport.acknowledge(receipt);
        _open();
        await journal.acknowledge(ack);
        confirmed[receipt.key] = ack;
        acknowledged++;
      } on AccessTransportFailure catch (error) {
        if (_fatal(error)) rethrow;
        issue(receipt.requestId, error.code, transportError: error);
        if (error.retryable || error.outcomeUnknown) postsAvailable = false;
      } on AccessFailure catch (error) {
        issue(receipt.requestId, error.code);
      }
    }

    Future<AccessReceipt> receive(
        AccessDocument document, AccessReference reference) async {
      final value = await journal.verifier
          .verify(document.signedDocument, restoration: true);
      document.requireMatch(value);
      reference.requireMatch(value);
      _open();
      final receipt = await journal.accept(document);
      await post(receipt);
      return receipt;
    }

    // A conflicting historical receipt does not prevent downloading revocation.
    for (final receipt in await journal.pendingReceipts()) {
      await post(receipt);
    }
    var position = await journal.scanPosition();
    bool more;
    do {
      _open();
      final page =
          await transport.list(cursor: position.cursor, limit: pageSize);
      _open();
      for (final reference in page.items) {
        _open();
        try {
          var document = await transport.document(reference.requestId);
          var receipt = await receive(document, reference);
          if (postsAvailable && await journal.prepareRetry(document)) {
            _open();
            try {
              await transport.retry(document);
              retried++;
              _open();
              document = await transport.document(reference.requestId);
              receipt = await receive(document, reference);
            } on AccessTransportFailure catch (error) {
              if (_fatal(error)) rethrow;
              if (error.status == 409 &&
                  {
                    'ACCESS_DOCUMENT_SUPERSEDED',
                    'ACCESS_RETRY_TOO_EARLY',
                    'ACCESS_RETRY_LIMIT',
                    'ACCESS_RETRY_NOT_ALLOWED'
                  }.contains(error.code)) {
                // Another coordinator or approval transition won the race.
                document = await transport.document(reference.requestId);
                receipt = await receive(document, reference);
              } else {
                issue(reference.requestId, error.code, transportError: error);
                if (error.retryable || error.outcomeUnknown) {
                  postsAvailable = false;
                }
              }
            }
          }
          if (receipt.phase == 'STORED') {
            stored++;
          } else {
            issue(reference.requestId, receipt.reasonCode!);
          }
        } on AccessFailure catch (error) {
          issue(reference.requestId, error.code);
        } on AccessTransportFailure catch (error) {
          if (_fatal(error) || error.retryable) rethrow;
          issue(reference.requestId, error.code, transportError: error);
        }
      }
      _open();
      await journal.advanceScan(position, page.nextCursor);
      pages++;
      more = page.nextCursor != null;
      position = await journal.scanPosition();
    } while (more && pages < maxPages);
    return AccessSyncResult(
        pages: pages,
        documentsStored: stored,
        receiptsAcknowledged: acknowledged,
        retriesCreated: retried,
        hasMore: more,
        pendingReceipts: (await journal.pendingReceipts()).length,
        issues: List.unmodifiable(issues));
  }

  /// Host scheduling hint. No unbounded timer or automatic mutation retry.
  Duration? retryDelay(AccessTransportFailure failure, int attempt) {
    if (attempt < 1 || attempt > 31) throw ArgumentError('Invalid retry count');
    if (!failure.retryable) return null;
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
