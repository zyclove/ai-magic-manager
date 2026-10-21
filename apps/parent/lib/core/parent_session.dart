import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'parent_api.dart';

/// Public native OIDC client. Production must supply one HTTPS origin reachable
/// by both Android and Keycloak; an Android emulator cannot use localhost here.
class ParentConfig {
  static const issuer = String.fromEnvironment('OIDC_ISSUER');
  static const apiUrl = String.fromEnvironment('API_URL');
  static const consoleUrl = String.fromEnvironment('CONSOLE_URL');
  static const clientId = 'ai-manager-parent';
  static const redirectUri = 'com.aimanager.parent:/oauth2redirect';
  static const wechatProvider = String.fromEnvironment('WECHAT_IDP_ALIAS');
  static const phoneProvider = String.fromEnvironment('PHONE_IDP_ALIAS');
  static const phoneLoginEnabled = bool.fromEnvironment('PHONE_LOGIN_ENABLED');
  static const wechatLoginEnabled =
      bool.fromEnvironment('WECHAT_LOGIN_ENABLED');
  static const accountSecurityEnabled =
      bool.fromEnvironment('FAMILY_ACCOUNT_SECURITY_ENABLED');

  static bool get valid {
    final identity = Uri.tryParse(issuer);
    final api = Uri.tryParse(apiUrl);
    return identity?.scheme == 'https' &&
        identity!.host.isNotEmpty &&
        api?.scheme == 'https' &&
        api!.host.isNotEmpty &&
        api.path.endsWith('/api/v1') &&
        !api.hasQuery &&
        !api.hasFragment;
  }

  static Uri? get console {
    final parsed = Uri.tryParse(consoleUrl);
    if (parsed?.scheme != 'https' ||
        parsed!.host.isEmpty ||
        parsed.userInfo.isNotEmpty ||
        parsed.hasQuery ||
        parsed.hasFragment) {
      return null;
    }
    return parsed;
  }
}

/// Stores only the refresh token persistently. Access and ID tokens live in RAM.
/// AppAuth handles authorization code, PKCE, discovery and token exchange.
class ParentSession extends ChangeNotifier {
  static const _refreshKey = 'parent.oidc.refresh';
  static const _workspaceKey = 'parent.workspace';
  final FlutterAppAuth _appAuth;
  final FlutterSecureStorage _storage;
  late final ParentApi api;
  late final ParentApi _identityApi;
  late final ParentApi accountSecurityApi;
  late final http.Client _authenticatedClient;

  String? _accessToken;
  String? _idToken;
  DateTime? _expiresAt;
  Future<void>? _refreshing;
  Future<void> _storageMutation = Future<void>.value();
  int _credentialEpoch = 0;
  bool _signingOut = false;
  bool _identityQuarantined = false;
  bool _preparingIdentityChange = false;

  /// Local guards finish while the original identity can still revoke its
  /// installation. A local shutdown failure must abort a voluntary switch.
  Future<void> Function()? beforeIdentityChange;
  Json? profile;
  List<Json> tenants = const [];
  Json? tenant;
  String role = '';
  bool ready = false;
  bool busy = false;
  Object? error;
  int generation = 0;
  String? _loginProvider;
  String? _wechatCode;
  String? _accountAction;
  String? _accountOperationId;
  int? _accountRevision;
  String? _accountExpectedActor;
  bool _accountActionMayHaveStarted = false;
  String? _accountStartedOperationId;
  bool get accountActionMayHaveStarted => _accountActionMayHaveStarted;
  bool accountActionMayHaveStartedFor(String operationId) =>
      _accountStartedOperationId == operationId;
  final MethodChannel _nativeAuth =
      const MethodChannel('com.aimanager.parent/auth');

  Future<bool> signInWithProvider(String provider) async {
    if (busy || _signingOut || _preparingIdentityChange) return false;
    final alias = provider == 'wechat'
        ? ParentConfig.wechatProvider
        : provider == 'phone'
            ? ParentConfig.phoneProvider
            : '';
    if (alias.isEmpty &&
        !(provider == 'phone' && ParentConfig.phoneLoginEnabled) &&
        !(provider == 'wechat' && ParentConfig.wechatLoginEnabled)) {
      error = const ParentApiException(503, 'FAMILY_LOGIN_UNAVAILABLE');
      notifyListeners();
      return false;
    }
    _loginProvider = alias.isEmpty ? null : alias;
    try {
      if (provider == 'wechat' && ParentConfig.wechatLoginEnabled) {
        busy = true;
        notifyListeners();
        final epoch = _credentialEpoch;
        final code = await _nativeAuth.invokeMethod<String>('wechatLogin');
        if (epoch != _credentialEpoch ||
            _signingOut ||
            code == null ||
            code.isEmpty ||
            code.length > 512) {
          throw const ParentApiException(401, 'LOGIN_FAILED');
        }
        _wechatCode = code;
        _loginProvider = null;
        busy = false;
      }
      return await signIn();
    } catch (_) {
      error = const ParentApiException(0, 'LOGIN_FAILED');
      return false;
    } finally {
      _loginProvider = null;
      _wechatCode = null;
      busy = false;
      notifyListeners();
    }
  }

  ParentSession(
      {FlutterAppAuth? appAuth,
      FlutterSecureStorage? storage,
      http.Client? client})
      : _appAuth = appAuth ?? const FlutterAppAuth(),
        _storage = storage ?? const FlutterSecureStorage() {
    api = ParentApi(token, baseUrl: ParentConfig.apiUrl, client: client);
    _identityApi = ParentApi(() => _sessionToken(verifiedRequired: false),
        baseUrl: ParentConfig.apiUrl, client: client);
    accountSecurityApi = ParentApi(() => _sessionToken(verifiedRequired: false),
        baseUrl: '${ParentConfig.issuer}/consumer-account', client: client);
    _authenticatedClient = _ParentAuthenticatedClient(token);
  }

  /// Shared with vetted workflow packages. Each request obtains a current
  /// access token; redirects cannot forward a bearer token to another origin.
  Future<http.Client> authenticatedClient() async {
    if (!authenticated) {
      throw const ParentApiException(401, 'UNAUTHENTICATED');
    }
    return _authenticatedClient;
  }

  bool get authenticated =>
      !_identityQuarantined && profile != null && _accessToken != null;
  bool get configured => ParentConfig.valid;
  bool get accountSecurityEnabled => ParentConfig.accountSecurityEnabled;
  bool get canDecide => const {'OWNER', 'GUARDIAN', 'ORG_ADMIN'}.contains(role);
  bool get canSeeHelp =>
      const {'OWNER', 'GUARDIAN', 'ORG_ADMIN', 'TEACHER'}.contains(role);
  String get root => '/tenants/${tenant!['id']}';
  String get displayName =>
      profile?['name'] as String? ?? profile?['email'] as String? ?? '监护人';

  Future<void> initialize() async {
    ready = false;
    error = null;
    notifyListeners();
    try {
      if (configured && await _storage.read(key: _refreshKey) != null) {
        await _refresh();
        await _loadIdentity();
      }
    } catch (failure) {
      debugPrint('ParentSession restore failed: ${failure.runtimeType}');
      error = failure is ParentApiException
          ? failure
          : const ParentApiException(0, 'LOGIN_FAILED');
      await _clear();
    } finally {
      ready = true;
      notifyListeners();
    }
  }

  Future<bool> signIn({bool stepUp = false, bool familyPhone = false}) async {
    if (busy || _signingOut || _preparingIdentityChange) return false;
    if (!configured) {
      error = const ParentApiException(0, 'CONFIGURATION_REQUIRED');
      notifyListeners();
      return false;
    }
    if (stepUp && profile?['subject'] is! String) {
      error = const ParentApiException(401, 'UNAUTHENTICATED');
      notifyListeners();
      return false;
    }
    // Revoke with the original JWT before a new authorization can replace it.
    // Step-up keeps its expected actor and is not an account switch.
    if (!stepUp && profile != null) await _prepareIdentityChange();
    busy = true;
    final epoch = _credentialEpoch;
    final expectedActor = _accountExpectedActor ??
        (stepUp ? (profile?['subject'] as String?) : null);
    final accountGeneration = _accountAction == null ? null : generation;
    bool exchanged = false;
    bool superseded = false;
    error = null;
    notifyListeners();
    try {
      final response = await _appAuth.authorizeAndExchangeCode(
        AuthorizationTokenRequest(
            ParentConfig.clientId, ParentConfig.redirectUri,
            issuer: ParentConfig.issuer,
            scopes: const [
              'openid',
              'profile',
              'email',
              'tenant:create'
            ],
            additionalParameters: {
              'ui_locales': 'zh-CN',
              if (_accountAction == null && _loginProvider != null)
                'kc_idp_hint': _loginProvider!,
              if (_wechatCode != null) 'family_wechat_code': _wechatCode!,
              if (_accountAction != null) ...{
                'family_account_action': _accountAction!,
                'family_account_operation': _accountOperationId!,
                if (_accountExpectedActor != null)
                  'family_account_actor': _accountExpectedActor!,
                if (_accountRevision != null)
                  'family_account_revision': '$_accountRevision',
              },
              if (_accountAction == null &&
                  stepUp &&
                  (familyPhone || tenant?['kind'] == 'FAMILY') &&
                  ParentConfig.phoneProvider.isNotEmpty)
                'kc_idp_hint': ParentConfig.phoneProvider,
              if (stepUp || _accountAction != null) 'max_age': '0',
            }),
      );
      exchanged = true;
      // A new authorization code invalidates any refresh started under the
      // previous credential generation; the new refresh token remains last.
      if (epoch != _credentialEpoch ||
          (accountGeneration != null && accountGeneration != generation)) {
        superseded = true;
        throw const ParentApiException(401, 'UNAUTHENTICATED');
      }
      final authorizationEpoch = ++_credentialEpoch;
      _identityQuarantined = true;
      await _accept(response, epoch: authorizationEpoch);
      await _loadIdentity(expectedActor: expectedActor);
      return true;
    } on FlutterAppAuthUserCancelledException {
      // Closing the system browser leaves the current session intact.
      return false;
    } catch (failure) {
      debugPrint('ParentSession login failed: ${failure.runtimeType}');
      error = failure is ParentApiException
          ? failure
          : const ParentApiException(0, 'LOGIN_FAILED');
      if (!superseded && (!stepUp || exchanged)) await _clear();
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Sensitive identity changes are completed by the IdP, using fresh SMS or
  /// linked WeChat proof. The caller journals its operation before opening the
  /// browser and confirms the result through the trusted status receipt.
  Future<bool> runAccountAction(
      {required String action,
      required String operationId,
      int? expectedRevision,
      String? expectedActor}) async {
    if (busy || _signingOut || _preparingIdentityChange) return false;
    _accountActionMayHaveStarted = false;
    const actions = {
      'CHANGE_PHONE',
      'BIND_WECHAT',
      'UNBIND_WECHAT',
      'RECOVER_PHONE'
    };
    final actor = profile?['subject'];
    final recovery = action == 'RECOVER_PHONE';
    if (!accountSecurityEnabled || !configured) {
      error = const ParentApiException(503, 'ACCOUNT_SECURITY_UNAVAILABLE');
      notifyListeners();
      return false;
    }
    if (!actions.contains(action) ||
        !RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
            .hasMatch(operationId) ||
        (expectedRevision != null &&
            (expectedRevision < 1 || expectedRevision > 9007199254740991)) ||
        (!recovery &&
            (!authenticated ||
                expectedActor != actor ||
                expectedRevision == null)) ||
        (authenticated && expectedActor != null && expectedActor != actor) ||
        (expectedActor != null &&
            (expectedActor.isEmpty || expectedActor.length > 255))) {
      error = const ParentApiException(409, 'ACCOUNT_OPERATION_CHANGED');
      notifyListeners();
      return false;
    }
    final epoch = _credentialEpoch;
    final scope = generation;
    busy = true;
    error = null;
    notifyListeners();
    try {
      // Stop local account-specific work while the original credentials still
      // work. The IdP will revoke existing sessions if the change commits.
      if (authenticated) await _prepareIdentityChange();
      if (action == 'BIND_WECHAT' || recovery) {
        final code = await _nativeAuth.invokeMethod<String>('wechatLogin');
        if (code == null || code.isEmpty || code.length > 512) {
          throw const ParentApiException(401, 'LOGIN_FAILED');
        }
        _wechatCode = code;
      }
      if (epoch != _credentialEpoch || scope != generation || _signingOut) {
        throw const ParentApiException(409, 'ACCOUNT_OPERATION_CHANGED');
      }
      _accountAction = action;
      _accountOperationId = operationId;
      _accountRevision = expectedRevision;
      _accountExpectedActor =
          expectedActor ?? (authenticated ? actor as String? : null);
      // signIn owns the browser interval's busy flag. No asynchronous gap here.
      busy = false;
      _accountActionMayHaveStarted = true;
      _accountStartedOperationId = operationId;
      return await signIn(stepUp: authenticated);
    } catch (failure) {
      error = failure is ParentApiException
          ? failure
          : failure is PlatformException &&
                  failure.code == 'WECHAT_NOT_INSTALLED'
              ? const ParentApiException(400, 'WECHAT_NOT_INSTALLED')
              : const ParentApiException(0, 'ACCOUNT_OPERATION_UNCONFIRMED');
      return false;
    } finally {
      _accountAction = null;
      _accountOperationId = null;
      _accountRevision = null;
      _accountExpectedActor = null;
      _wechatCode = null;
      busy = false;
      notifyListeners();
    }
  }

  /// Call immediately before sensitive mutation. The API remains the authority
  /// for checking auth_time and MFA; a local flag never grants permission.
  Future<bool> reauthenticate() async {
    return await signIn(stepUp: true) && error == null && authenticated;
  }

  Future<bool> reauthenticateFamily() async {
    return await signIn(stepUp: true, familyPhone: true) &&
        error == null &&
        authenticated;
  }

  /// The server decides whether the existing authentication is recent enough.
  /// Retry only its definite pre-mutation rejection, never an unknown outcome.
  Future<T> pairingRequest<T>(Future<T> Function() action,
      {required bool Function() isCurrent}) async {
    if (!isCurrent()) throw const ParentApiException(409, 'SCOPE_DENIED');
    try {
      return await action();
    } on ParentApiException catch (failure) {
      if (failure.status != 401 || failure.code != 'REAUTH_REQUIRED') rethrow;
      if (!isCurrent()) throw const ParentApiException(409, 'SCOPE_DENIED');
      if (!await reauthenticate()) {
        throw const ParentApiException(401, 'REAUTH_REQUIRED');
      }
      if (!isCurrent()) throw const ParentApiException(409, 'SCOPE_DENIED');
      return action();
    }
  }

  Future<String> token() => _sessionToken();
  Future<String> _sessionToken({bool verifiedRequired = true}) async {
    if (_signingOut ||
        (verifiedRequired && _identityQuarantined) ||
        _accessToken == null) {
      throw const ParentApiException(401, 'UNAUTHENTICATED');
    }
    if (_expiresAt == null ||
        _expiresAt!.isBefore(DateTime.now().add(const Duration(seconds: 45)))) {
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
      await _refreshing;
    }
    final value = _accessToken;
    if (value == null || (verifiedRequired && _identityQuarantined)) {
      throw const ParentApiException(401, 'UNAUTHENTICATED');
    }
    return value;
  }

  Future<void> _refresh() async {
    final epoch = _credentialEpoch;
    final refresh = await _storage.read(key: _refreshKey);
    if (epoch != _credentialEpoch) {
      throw const ParentApiException(401, 'UNAUTHENTICATED');
    }
    if (refresh == null) throw const ParentApiException(401, 'UNAUTHENTICATED');
    final response = await _appAuth.token(TokenRequest(
        ParentConfig.clientId, ParentConfig.redirectUri,
        issuer: ParentConfig.issuer,
        refreshToken: refresh,
        scopes: const ['openid', 'profile', 'email', 'tenant:create']));
    await _accept(response, epoch: epoch, previousRefresh: refresh);
  }

  Future<void> _accept(TokenResponse response,
      {required int epoch, String? previousRefresh}) async {
    if (response.accessToken == null || response.accessToken!.isEmpty) {
      throw const ParentApiException(401, 'UNAUTHENTICATED');
    }
    final refresh = response.refreshToken ?? previousRefresh;
    if (refresh == null || refresh.isEmpty) {
      throw const ParentApiException(401, 'UNAUTHENTICATED');
    }
    if (epoch != _credentialEpoch) {
      throw const ParentApiException(401, 'UNAUTHENTICATED');
    }
    await _enqueueStorage(() async {
      if (epoch == _credentialEpoch) {
        await _storage.write(key: _refreshKey, value: refresh);
      }
    });
    if (epoch != _credentialEpoch) {
      throw const ParentApiException(401, 'UNAUTHENTICATED');
    }
    _accessToken = response.accessToken;
    _idToken = response.idToken;
    _expiresAt = response.accessTokenExpirationDateTime;
  }

  Future<void> _loadIdentity({String? expectedActor}) async {
    final epoch = _credentialEpoch;
    final identityGeneration = generation;
    final identityApi = _identityQuarantined ? _identityApi : api;
    final me = await identityApi.object('/me');
    if (me['subject'] is! String || (me['subject'] as String).isEmpty) {
      throw const ParentApiException(502, 'INVALID_RESPONSE');
    }
    if (expectedActor != null && me['subject'] != expectedActor) {
      throw const ParentApiException(401, 'UNAUTHENTICATED');
    }
    final workspaces = await identityApi.all('/tenants');
    final selected = await _storage.read(key: _workspaceKey);
    Json? next;
    String nextRole = '';
    if (workspaces.isNotEmpty) {
      next = workspaces.firstWhere((item) => item['id'] == selected,
          orElse: () => workspaces.first);
      final membership =
          await identityApi.object('/tenants/${next['id']}/membership');
      nextRole = membership['role'] as String? ?? '';
    }
    if (epoch != _credentialEpoch || identityGeneration != generation) {
      throw const ParentApiException(401, 'UNAUTHENTICATED');
    }
    // Publish an identity and its membership together. A failed membership read
    // must not leave an adult profile paired with a stale workspace role.
    if (profile != null &&
        (profile?['subject'] != me['subject'] ||
            tenant?['id'] != next?['id'] ||
            role != nextRole)) {
      await _prepareIdentityChange();
      if (epoch != _credentialEpoch || identityGeneration != generation) {
        throw const ParentApiException(401, 'UNAUTHENTICATED');
      }
    }
    generation++;
    profile = me;
    tenants = workspaces;
    tenant = next;
    role = nextRole;
    _identityQuarantined = false;
    notifyListeners();
  }

  Future<void> selectTenant(Json next) async {
    final id = next['id'];
    if (id is! String || !tenants.any((item) => item['id'] == id)) {
      throw const ParentApiException(403, 'SCOPE_DENIED');
    }
    if (id == tenant?['id']) return;
    if (_preparingIdentityChange || _signingOut) {
      throw const ParentApiException(409, 'WORKSPACE_CHANGED');
    }
    await _prepareIdentityChange();
    final epoch = ++generation;
    try {
      final membership = await api.object('/tenants/$id/membership');
      if (epoch != generation) return;
      final nextRole = membership['role'] as String? ?? '';
      await _enqueueStorage(() async {
        if (epoch == generation && authenticated) {
          await _storage.write(key: _workspaceKey, value: id);
        }
      });
      if (epoch != generation) return;
      tenant = next;
      role = nextRole;
    } finally {
      // Failed reads still invalidate old private pages and must allow the
      // original family to reload under the new generation.
      if (epoch == generation) notifyListeners();
    }
  }

  Future<void> refreshWorkspaces() async {
    if (!authenticated) throw const ParentApiException(401, 'UNAUTHENTICATED');
    await _loadIdentity(expectedActor: profile?['subject'] as String?);
  }

  Future<void> _enqueueStorage(Future<void> Function() action) {
    final current = _storageMutation.then((_) => action());
    _storageMutation = current.then<void>((_) {}, onError: (Object _) {});
    return current;
  }

  Future<void> _prepareIdentityChange() async {
    if (_preparingIdentityChange) {
      throw const ParentApiException(409, 'WORKSPACE_CHANGED');
    }
    _preparingIdentityChange = true;
    try {
      await beforeIdentityChange?.call();
    } finally {
      _preparingIdentityChange = false;
    }
  }

  Future<void> _clear({bool guardPrepared = false}) async {
    if (!guardPrepared) await _prepareIdentityChange();
    _credentialEpoch++;
    generation++;
    _accessToken = null;
    _idToken = null;
    _expiresAt = null;
    _identityQuarantined = false;
    profile = null;
    tenants = const [];
    tenant = null;
    role = '';
    await _enqueueStorage(() async {
      await _storage.delete(key: _refreshKey);
      await _storage.delete(key: _workspaceKey);
    });
  }

  Future<void> signOut() async {
    if (_signingOut || _preparingIdentityChange) return;
    await _prepareIdentityChange();
    _signingOut = true;
    final idToken = _idToken;
    try {
      await _clear(guardPrepared: true);
      notifyListeners();
      if (idToken != null) {
        try {
          await _appAuth.endSession(EndSessionRequest(
            idTokenHint: idToken,
            issuer: ParentConfig.issuer,
            postLogoutRedirectUrl: ParentConfig.redirectUri,
          ));
        } catch (_) {
          // Local credentials are already removed; browser SSO may still exist.
        }
      }
    } finally {
      _signingOut = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    api.close();
    _identityApi.close();
    accountSecurityApi.close();
    _authenticatedClient.close();
    super.dispose();
  }
}

class _ParentAuthenticatedClient extends http.BaseClient {
  final Future<String> Function() token;
  final http.Client _inner = http.Client();
  _ParentAuthenticatedClient(this.token);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    request.followRedirects = false;
    request.headers['Authorization'] = 'Bearer ${await token()}';
    request.headers['Cache-Control'] = 'no-store';
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
