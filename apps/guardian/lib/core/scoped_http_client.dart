import 'package:http/http.dart' as http;

class ScopeChangedException implements Exception {
  const ScopeChangedException();
}

/// Keeps a request tied to the scope that authorized its creation.
class ScopeGuardedRequest extends http.Request {
  final bool Function() isCurrent;
  ScopeGuardedRequest(super.method, super.url, {required this.isCurrent});

  void ensureCurrent() {
    if (!isCurrent()) throw const ScopeChangedException();
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
    if (request is ScopeGuardedRequest) request.ensureCurrent();
    return inner.send(request);
  }

  @override
  void close() => inner.close();
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
