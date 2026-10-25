import 'dart:async';

import 'package:http/http.dart' as http;

class ScopeChangedException implements Exception {
  const ScopeChangedException();
}

abstract interface class _ScopeCheckedRequest {
  void ensureCurrent();
}

/// Keeps a request tied to the scope that authorized its creation.
class ScopeGuardedRequest extends http.Request
    implements _ScopeCheckedRequest, http.Abortable {
  final bool Function() isCurrent;
  final bool Function()? isAborted;
  @override
  final Future<void>? abortTrigger;
  ScopeGuardedRequest(super.method, super.url,
      {required this.isCurrent, this.abortTrigger, this.isAborted});

  @override
  void ensureCurrent() {
    if (!isCurrent()) throw const ScopeChangedException();
    if (isAborted?.call() == true) {
      throw http.RequestAbortedException(url);
    }
  }

  @override
  http.ByteStream finalize() {
    ensureCurrent();
    return super.finalize();
  }
}

/// OAuth forwards the original request here after awaiting credential refresh.
/// Check synchronously before the delegate is allowed to receive that request.
class ScopeGuardedClient extends http.BaseClient {
  final http.Client inner;
  ScopeGuardedClient(this.inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is _ScopeCheckedRequest) {
      (request as _ScopeCheckedRequest).ensureCurrent();
    }
    return inner.send(request);
  }

  @override
  void close() => inner.close();
}

/// Adds a scope to arbitrary requests while borrowing the authenticated client.
/// OAuth keeps this request wrapper through refresh, so the physical transport
/// can check both the new binding and any guard on the original request.
class ScopeBindingClient extends http.BaseClient {
  final http.Client inner;
  final bool Function() isCurrent;
  ScopeBindingClient(this.inner, {required this.isCurrent});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bound = _ScopeBoundRequest(request, isCurrent);
    bound.ensureCurrent();
    final http.StreamedResponse response;
    try {
      response = await inner.send(bound);
    } catch (_) {
      bound.ensureCurrent();
      rethrow;
    }
    try {
      bound.ensureCurrent();
    } catch (_) {
      // Headers have arrived, but no caller owns the private body yet.
      // Cancellation is best effort; a cleanup failure must not expose it.
      try {
        await response.stream.listen(null).cancel();
      } catch (_) {}
      rethrow;
    }
    return http.StreamedResponse(
        _guardResponse(response.stream, bound.ensureCurrent),
        response.statusCode,
        contentLength: response.contentLength,
        request: response.request,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase);
  }

  /// The session owns OAuth and its transport; a temporary view cannot close it.
  @override
  void close() {}
}

class _ScopeBoundRequest extends http.BaseRequest
    implements _ScopeCheckedRequest, http.Abortable {
  final http.BaseRequest inner;
  final bool Function() isCurrent;

  _ScopeBoundRequest(this.inner, this.isCurrent)
      : super(inner.method, inner.url);

  @override
  Future<void>? get abortTrigger {
    final original = inner;
    return original is http.Abortable ? original.abortTrigger : null;
  }

  // Share headers so OAuth additions and finalize-time headers (for example a
  // multipart boundary) remain attached to the exact original body stream.
  @override
  Map<String, String> get headers => inner.headers;

  @override
  int? get contentLength => inner.contentLength;
  @override
  set contentLength(int? value) => inner.contentLength = value;

  @override
  bool get followRedirects => inner.followRedirects;
  @override
  set followRedirects(bool value) => inner.followRedirects = value;

  @override
  int get maxRedirects => inner.maxRedirects;
  @override
  set maxRedirects(int value) => inner.maxRedirects = value;

  @override
  bool get persistentConnection => inner.persistentConnection;
  @override
  set persistentConnection(bool value) => inner.persistentConnection = value;

  @override
  void ensureCurrent() {
    if (!isCurrent()) throw const ScopeChangedException();
    final original = inner;
    if (original is _ScopeCheckedRequest) {
      (original as _ScopeCheckedRequest).ensureCurrent();
    }
  }

  @override
  http.ByteStream finalize() {
    ensureCurrent();
    super.finalize();
    return inner.finalize();
  }
}

Stream<List<int>> _guardResponse(
    Stream<List<int>> source, void Function() ensureCurrent) {
  StreamSubscription<List<int>>? upstream;
  Future<void>? cancellation;
  bool ended = false;
  late final StreamController<List<int>> output;
  Future<void> cancelSource() => cancellation ??= Future<void>.sync(() async {
        try {
          await upstream?.cancel();
        } catch (_) {
          // Cancellation is cleanup; preserve the original response/guard error.
        }
      });
  void fail(Object error, StackTrace trace) {
    if (ended) return;
    ended = true;
    output.addError(error, trace);
    // Clean up the source even if the consumer stops on this error. A cleanup
    // failure must not replace the guard error or disclose the private body.
    unawaited(cancelSource().then<void>((_) {
      output.close();
    }, onError: (Object _, StackTrace __) {
      output.close();
    }));
  }

  output = StreamController<List<int>>(
      onListen: () {
        try {
          ensureCurrent();
        } catch (error, trace) {
          upstream = source.listen(null, onError: (Object _, StackTrace __) {});
          fail(error, trace);
          return;
        }
        upstream = source.listen(
            (chunk) {
              if (ended) return;
              try {
                ensureCurrent();
                output.add(chunk);
              } catch (error, trace) {
                fail(error, trace);
              }
            },
            onError: fail,
            onDone: () {
              if (ended) return;
              try {
                ensureCurrent();
                ended = true;
                output.close();
              } catch (error, trace) {
                fail(error, trace);
              }
            });
      },
      onPause: () => upstream?.pause(),
      onResume: () => upstream?.resume(),
      onCancel: () {
        ended = true;
        return cancelSource();
      });
  bool deliveredError = false;
  // A source event can wait in this controller while the consumer is paused.
  // Check again at delivery, after any asynchronous queue or pause/resume.
  return output.stream.transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
          handleData: (chunk, sink) {
    if (deliveredError) return;
    try {
      ensureCurrent();
      sink.add(chunk);
    } catch (error, trace) {
      deliveredError = true;
      ended = true;
      sink.addError(error, trace);
      unawaited(cancelSource().then<void>((_) {
        if (!output.isClosed) output.close();
      }));
    }
  }, handleError: (error, trace, sink) {
    if (deliveredError) return;
    deliveredError = true;
    try {
      ensureCurrent();
      sink.addError(error, trace);
    } catch (scopeError, scopeTrace) {
      sink.addError(scopeError, scopeTrace);
    }
  }, handleDone: (sink) {
    if (!deliveredError) {
      try {
        ensureCurrent();
      } catch (error, trace) {
        sink.addError(error, trace);
      }
    }
    sink.close();
  }));
}

/// Credential persistence belongs to one authentication lifetime. Workspace
/// changes deliberately leave this owner valid for the same signed-in account.
class AuthenticationOwner {
  Object? _current;

  Object begin() {
    final owner = Object();
    _current = owner;
    return owner;
  }

  bool isCurrent(Object owner) => identical(_current, owner);

  void invalidate() => _current = null;

  void saveIfCurrent(Object owner, void Function() save) {
    if (isCurrent(owner)) save();
  }
}
