import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/ui/managed_execution_controller.dart';
import 'managed_execution_fixtures.dart';

void main() {
  late ExecutionFixture f;
  late ManagedExecutionController c;
  setUp(() {
    f = ExecutionFixture();
    c = ManagedExecutionController(
        repository: f.repository(), registrationId: executionRegistration);
  });
  tearDown(() {
    c.dispose();
    f.client.close();
  });

  Future<void> open() async {
    await c.load();
    await c.open(c.items.single);
  }

  test('loads device records and verified detail with event timeline',
      () async {
    await open();
    expect(c.items.single.id, executionId);
    expect(c.selected?.revision, 1);
    expect(c.events.single.revision, 1);
    expect(c.canCancel, isTrue);
    expect(c.busy, isFalse);
  });

  test('changing the filter drops previous pages and selection', () async {
    await open();
    f.handler = (r) async => f.response({'items': [], 'nextCursor': null});
    await c.load(state: 'APPLIED');
    expect(c.filter, 'APPLIED');
    expect(c.items, isEmpty);
    expect(c.selected, isNull);
    expect(c.events, isEmpty);
    expect(f.requests.last.url.queryParameters['state'], 'APPLIED');
    expect(f.requests.last.url.queryParameters.containsKey('cursor'), isFalse);
  });

  test('rejects a cross-page duplicate without discarding the first page',
      () async {
    var reads = 0;
    f.handler = (r) async {
      reads++;
      return f.response({
        'items': reads == 1
            ? [
                f.record(id: executionOther, createdAt: 200, updatedAt: 200),
                f.record()
              ]
            : [f.record(id: executionOther, createdAt: 200, updatedAt: 200)],
        'nextCursor': reads == 1 ? executionId : null
      });
    };
    await c.load();
    await c.loadMore();
    expect(c.items.map((x) => x.id), [executionOther, executionId]);
    expect(c.listError, isA<ApiFailure>());
    expect(
        (c.listError as ApiFailure).code, 'INVALID_MANAGED_EXECUTION_RESPONSE');
    expect(f.requests.last.url.queryParameters['cursor'], executionId);
  });

  test('a valid second page appends once and stops at the last page', () async {
    f.handler =
        (r) async => f.response(r.url.queryParameters.containsKey('cursor')
            ? {
                'items': [
                  f.record(id: executionOther, createdAt: 90, updatedAt: 90)
                ],
                'nextCursor': null
              }
            : {
                'items': [f.record()],
                'nextCursor': executionId
              });
    await c.load();
    expect(f.requests.length, 1);
    await c.loadMore();
    await c.loadMore();
    expect(c.items.map((x) => x.id), [executionId, executionOther]);
    expect(f.requests.length, 2);
    expect(f.requests.last.url.queryParameters['cursor'], executionId);
    expect(c.listError, isNull);
  });

  test('event pages append in order only after explicit load more', () async {
    f.handler = (r) async {
      if (r.url.path.endsWith('/events')) {
        return f.response(r.url.queryParameters.containsKey('cursor')
            ? {
                'items': [f.event(revision: 2)],
                'nextCursor': null
              }
            : {
                'items': [f.event()],
                'nextCursor': '1'
              });
      }
      if (r.url.path.endsWith('/$executionId')) {
        return f.response(f.record(revision: 2));
      }
      return f.response({
        'items': [f.record(revision: 2)],
        'nextCursor': null
      });
    };
    await open();
    expect(c.events.map((x) => x.revision), [1]);
    expect(f.requests.where((r) => r.url.path.endsWith('/events')).length, 1);
    await c.loadMoreEvents();
    await c.loadMoreEvents();
    expect(c.events.map((x) => x.revision), [1, 2]);
    expect(f.requests.last.url.queryParameters['cursor'], '1');
    expect(f.requests.where((r) => r.url.path.endsWith('/events')).length, 2);
    expect(c.eventError, isNull);
  });

  test('scope loss clears private data and prevents further reads', () async {
    await open();
    final before = f.requests.length;
    f.current = false;
    c.checkScope();
    await c.load();
    expect(c.hasAccess, isFalse);
    expect(c.items, isEmpty);
    expect(c.selected, isNull);
    expect(c.events, isEmpty);
    expect(f.requests.length, before);
    f.current = true;
    await c.load();
    expect(c.hasAccess, isFalse);
    expect(f.requests.length, before);
  });

  test('late list response cannot repopulate a lost scope', () async {
    final response = Completer<void>();
    f.handler = (r) async {
      await response.future;
      return f.response({
        'items': [f.record()],
        'nextCursor': null
      });
    };
    final pending = c.load();
    await Future<void>.delayed(Duration.zero);
    f.current = false;
    c.checkScope();
    response.complete();
    await pending;
    expect(c.items, isEmpty);
    expect(c.hasAccess, isFalse);
  });

  test('a late response cannot overwrite a newer filter', () async {
    final first = Completer<void>();
    f.handler = (r) async {
      if (r.url.queryParameters['state'] == 'APPLIED') {
        return f.response({'items': [], 'nextCursor': null});
      }
      await first.future;
      return f.response({
        'items': [f.record()],
        'nextCursor': null
      });
    };
    final pending = c.load();
    await Future<void>.delayed(Duration.zero);
    await c.load(state: 'APPLIED');
    first.complete();
    await pending;
    expect(c.filter, 'APPLIED');
    expect(c.items, isEmpty);
    expect(c.listError, isNull);
  });

  test('invalid pagination cursor reloads the first page with the same filter',
      () async {
    f.handler = (r) async {
      if (r.url.queryParameters.containsKey('cursor')) {
        return f.response({'errorCode': 'INVALID_CURSOR'}, status: 400);
      }
      return f.response({
        'items': [f.record()],
        'nextCursor': executionId
      });
    };
    await c.load(state: 'READY_TO_WRITE');
    await c.loadMore();
    expect(c.items.length, 1);
    expect(c.filter, 'READY_TO_WRITE');
    expect(f.requests.length, 3);
    expect(f.requests.last.url.queryParameters.containsKey('cursor'), isFalse);
  });

  test('closing detail rejects its late response', () async {
    await c.load();
    final detail = Completer<void>();
    f.handler = (r) async {
      await detail.future;
      return f.response(f.record());
    };
    final pending = c.open(c.items.single);
    await Future<void>.delayed(Duration.zero);
    c.back();
    detail.complete();
    await pending;
    expect(c.selected, isNull);
    expect(c.events, isEmpty);
  });

  test('declining confirmation sends no cancel request', () async {
    await open();
    await c.cancel((_) async => false);
    expect(f.requests.where((r) => r.method == 'POST'), isEmpty);
    expect(c.canCancel, isTrue);
  });

  test('confirmation blocks a captured duplicate action', () async {
    await open();
    final confirm = Completer<bool>();
    var prompts = 0;
    final pending = c.cancel((_) {
      prompts++;
      return confirm.future;
    });
    await c.cancel((_) async {
      prompts++;
      return true;
    });
    expect(prompts, 1);
    confirm.complete(true);
    await pending;
    expect(f.requests.where((r) => r.method == 'POST').length, 1);
    expect(c.selected?.state, 'CANCELLED');
    expect(c.canCancel, isFalse);
  });

  test('scope loss during confirmation sends no write', () async {
    await open();
    final confirm = Completer<bool>();
    final pending = c.cancel((_) => confirm.future);
    f.current = false;
    c.checkScope();
    confirm.complete(true);
    await pending;
    expect(f.requests.where((r) => r.method == 'POST'), isEmpty);
    expect(c.selected, isNull);
  });

  test('historical registration never prompts for cancellation', () async {
    f.handler = (r) async => r.url.path.endsWith('/events')
        ? f.response({'items': [], 'nextCursor': null})
        : r.url.path.endsWith('/$executionId')
            ? f.response(f.record(registration: executionOther))
            : f.response({
                'items': [f.record(registration: executionOther)],
                'nextCursor': null
              });
    await open();
    var prompts = 0;
    await c.cancel((_) async {
      prompts++;
      return true;
    });
    expect(c.historical, isTrue);
    expect(c.canCancel, isFalse);
    expect(prompts, 0);
  });

  test('read-only repository cannot prompt or dispatch cancellation', () async {
    c.dispose();
    c = ManagedExecutionController(
        repository: f.repository(writable: false),
        registrationId: executionRegistration);
    await open();
    var prompts = 0;
    await c.cancel((_) async {
      prompts++;
      return true;
    });
    expect(prompts, 0);
    expect(f.requests.where((r) => r.method == 'POST'), isEmpty);
  });

  test('uncertain cancel stays read-only after an old READY response',
      () async {
    await open();
    f.handler = (r) async {
      if (r.method == 'POST') throw const ApiFailure(0, 'NETWORK_ERROR');
      if (r.url.path.endsWith('/events')) {
        return f.response({'items': [], 'nextCursor': null});
      }
      return f.response(f.record());
    };
    await c.cancel((_) async => true);
    expect(c.resultUnknown, isTrue);
    await c.refreshDetail();
    expect(c.selected?.state, 'READY_TO_WRITE');
    expect(c.resultUnknown, isTrue);
    await c.cancel((_) async => true);
    expect(f.requests.where((r) => r.method == 'POST').length, 1);
  });

  test('switching away and back cannot clear an uncertain cancellation',
      () async {
    await open();
    f.handler = (r) async {
      if (r.method == 'POST') throw const ApiFailure(0, 'NETWORK_ERROR');
      if (r.url.path.endsWith('/events')) {
        return f.response({'items': [], 'nextCursor': null});
      }
      return f.response(f.record());
    };
    await c.cancel((_) async => true);
    c.back();
    await c.open(c.items.single);
    expect(c.resultUnknown, isTrue);
    expect(c.canCancel, isFalse);
  });

  test('filter reload cannot clear an uncertain cancellation for the same task',
      () async {
    await open();
    f.handler = (r) async {
      if (r.method == 'POST') throw const ApiFailure(0, 'NETWORK_ERROR');
      if (r.url.path.endsWith('/events')) {
        return f.response({'items': [], 'nextCursor': null});
      }
      if (r.url.path.endsWith('/$executionId')) return f.response(f.record());
      return f.response({
        'items': [f.record()],
        'nextCursor': null
      });
    };
    await c.cancel((_) async => true);
    await c.load(state: 'READY_TO_WRITE');
    await c.open(c.items.single);
    expect(c.resultUnknown, isTrue);
    expect(c.canCancel, isFalse);
    expect(f.requests.where((r) => r.method == 'POST').length, 1);
  });

  test(
      'accepted cancellation requiring review never becomes a cancelled success',
      () async {
    await open();
    f.handler = (r) async {
      if (r.method == 'POST') {
        return f.response(f.record(
            state: 'NEEDS_REVIEW',
            reason: 'CANCELLATION_REQUIRES_REVIEW',
            revision: 2,
            cancelled: true));
      }
      return f.response({'items': [], 'nextCursor': null});
    };
    await c.cancel((_) async => true);
    expect(c.selected?.state, 'NEEDS_REVIEW');
    expect(c.selected?.cancellationRequested, isTrue);
    expect(c.resultUnknown, isFalse);
    expect(c.canCancel, isFalse);
  });

  test(
      'invalid successful cancel response enters a persistent check-only state',
      () async {
    await open();
    f.handler = (r) async {
      if (r.url.path.endsWith('/events')) {
        return f.response({'items': [], 'nextCursor': null});
      }
      return f.response(
          f.record()); // 200, unchanged revision and no cancellation flag.
    };
    await c.cancel((_) async => true);
    expect(c.resultUnknown, isTrue);
    await c.refreshDetail();
    await c.cancel((_) async => true);
    expect(c.canCancel, isFalse);
    expect(f.requests.where((r) => r.method == 'POST').length, 1);
  });

  test('412 refreshes detail but never automatically repeats cancel', () async {
    await open();
    f.handler = (r) async {
      if (r.method == 'POST') {
        return f.response({'errorCode': 'VERSION_MISMATCH'}, status: 412);
      }
      if (r.url.path.endsWith('/events')) {
        return f.response({'items': [], 'nextCursor': null});
      }
      return f.response(f.record(revision: 2));
    };
    await c.cancel((_) async => true);
    expect(c.selected?.revision, 2);
    expect(c.notice, isNotNull);
    expect(c.resultUnknown, isFalse);
    expect(f.requests.where((r) => r.method == 'POST').length, 1);
    f.handler = (r) async {
      if (r.method == 'POST') {
        return f.response(f.record(
            state: 'CANCELLED',
            reason: 'CANCELLED_BEFORE_ASSIGNMENT',
            revision: 3,
            cancelled: true));
      }
      return f.response({'items': [], 'nextCursor': null});
    };
    var confirmations = 0;
    await c.cancel((_) async {
      confirmations++;
      return true;
    });
    expect(confirmations, 1);
    expect(f.requests.lastWhere((r) => r.method == 'POST').headers['If-Match'],
        '"2"');
  });

  test('recent authentication requirement clears write eligibility', () async {
    await open();
    f.handler =
        (r) async => f.response({'errorCode': 'REAUTH_REQUIRED'}, status: 401);
    await c.cancel((_) async => true);
    expect(c.needsReauth, isTrue);
    expect(c.canCancel, isFalse);
    expect(c.hasAccess, isTrue);
    expect(c.resultUnknown, isFalse);
  });

  for (final status in [401, 403]) {
    test('authorization status $status redacts records', () async {
      await open();
      f.handler = (r) async =>
          f.response({'errorCode': 'SCOPE_DENIED'}, status: status);
      await c.refreshDetail();
      expect(c.hasAccess, isFalse);
      expect(c.items, isEmpty);
      expect(c.selected, isNull);
      expect(c.events, isEmpty);
    });
  }

  test('events newer than detail block stale cancellation until detail refresh',
      () async {
    f.handler = (r) async {
      if (r.url.path.endsWith('/events')) {
        return f.response({
          'items': [f.event(revision: 2)],
          'nextCursor': null
        });
      }
      if (r.url.path.endsWith('/$executionId')) return f.response(f.record());
      return f.response({
        'items': [f.record()],
        'nextCursor': null
      });
    };
    await open();
    expect(c.events.single.revision, 2);
    expect(c.eventsAhead, isTrue);
    expect(c.canCancel, isFalse);
    f.handler = (r) async => r.url.path.endsWith('/events')
        ? f.response({
            'items': [f.event(revision: 2)],
            'nextCursor': null
          })
        : f.response(f.record(revision: 2));
    await c.refreshDetail();
    expect(c.eventsAhead, isFalse);
    expect(c.canCancel, isTrue);
    expect(c.detailError, isNull);
    expect(c.eventError, isNull);
  });

  test('event progress is not forgotten when timeline refresh fails', () async {
    f.handler = (r) async {
      if (r.url.path.endsWith('/events')) {
        return f.response({
          'items': [f.event(revision: 2)],
          'nextCursor': null
        });
      }
      if (r.url.path.endsWith('/$executionId')) return f.response(f.record());
      return f.response({
        'items': [f.record()],
        'nextCursor': null
      });
    };
    await open();
    expect(c.eventsAhead, isTrue);
    f.handler = (r) async {
      if (r.url.path.endsWith('/events')) {
        throw const ApiFailure(0, 'NETWORK_ERROR');
      }
      return f.response(f.record());
    };
    await c.refreshDetail();
    expect(c.eventError, isA<ApiFailure>());
    expect(c.eventsAhead, isTrue);
    await c.cancel((_) async => true);
    expect(f.requests.where((r) => r.method == 'POST'), isEmpty);
  });

  test('highest event revision survives resetting to an earlier timeline page',
      () async {
    f.handler = (r) async {
      if (r.url.path.endsWith('/events')) {
        return f.response(r.url.queryParameters.containsKey('cursor')
            ? {
                'items': [f.event(revision: 2)],
                'nextCursor': null
              }
            : {
                'items': [f.event()],
                'nextCursor': '1'
              });
      }
      if (r.url.path.endsWith('/$executionId')) return f.response(f.record());
      return f.response({
        'items': [f.record()],
        'nextCursor': null
      });
    };
    await open();
    await c.loadMoreEvents();
    expect(c.eventsAhead, isTrue);
    await c.refreshDetail();
    expect(c.events.single.revision, 1);
    expect(c.eventsAhead, isTrue);
    c.back();
    await c.open(c.items.single);
    expect(c.eventsAhead, isTrue);
    expect(c.canCancel, isFalse);
  });

  test('updated record is removed from a filter it no longer matches',
      () async {
    await c.load(state: 'READY_TO_WRITE');
    await c.open(c.items.single);
    await c.cancel((_) async => true);
    expect(c.selected?.state, 'CANCELLED');
    c.back();
    expect(c.filter, 'READY_TO_WRITE');
    expect(c.items, isEmpty);
  });
}
