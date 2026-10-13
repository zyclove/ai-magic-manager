import 'package:flutter/foundation.dart';
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
  late final http.Client _authenticatedClient;

  String? _accessToken;
  String? _idToken;
  DateTime? _expiresAt;
  Future<void>? _refreshing;
  Json? profile;
  List<Json> tenants = const [];
  Json? tenant;
  String role = '';
  bool ready = false;
  bool busy = false;
  Object? error;
  int generation = 0;

  ParentSession({FlutterAppAuth? appAuth, FlutterSecureStorage? storage})
      : _appAuth = appAuth ?? const FlutterAppAuth(),
        _storage = storage ?? const FlutterSecureStorage() {
    api = ParentApi(token, baseUrl: ParentConfig.apiUrl);
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

  bool get authenticated => profile != null && _accessToken != null;
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
      if (ParentConfig.valid && await _storage.read(key: _refreshKey) != null) {
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

  Future<bool> signIn({bool stepUp = false}) async {
    if (busy) return false;
    if (!ParentConfig.valid) {
      error = const ParentApiException(0, 'CONFIGURATION_REQUIRED');
      notifyListeners();
      return false;
    }
    busy = true;
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
              if (stepUp) 'max_age': '0',
            }),
      );
      await _accept(response);
      await _loadIdentity();
      return true;
    } on FlutterAppAuthUserCancelledException {
      // Closing the system browser leaves the current session intact.
      return false;
    } catch (failure) {
      debugPrint('ParentSession login failed: ${failure.runtimeType}');
      error = failure is ParentApiException
          ? failure
          : const ParentApiException(0, 'LOGIN_FAILED');
      if (!stepUp) await _clear();
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Call immediately before sensitive mutation. The API remains the authority
  /// for checking auth_time and MFA; a local flag never grants permission.
  Future<bool> reauthenticate() async {
    return await signIn(stepUp: true) && error == null && authenticated;
  }

  Future<String> token() async {
    if (_accessToken == null ||
        _expiresAt == null ||
        _expiresAt!.isBefore(DateTime.now().add(const Duration(seconds: 45)))) {
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
      await _refreshing;
    }
    final value = _accessToken;
    if (value == null) throw const ParentApiException(401, 'UNAUTHENTICATED');
    return value;
  }

  Future<void> _refresh() async {
    final refresh = await _storage.read(key: _refreshKey);
    if (refresh == null) throw const ParentApiException(401, 'UNAUTHENTICATED');
    final response = await _appAuth.token(TokenRequest(
        ParentConfig.clientId, ParentConfig.redirectUri,
        issuer: ParentConfig.issuer,
        refreshToken: refresh,
        scopes: const ['openid', 'profile', 'email', 'tenant:create']));
    await _accept(response, previousRefresh: refresh);
  }

  Future<void> _accept(TokenResponse response,
      {String? previousRefresh}) async {
    if (response.accessToken == null || response.accessToken!.isEmpty) {
      throw const ParentApiException(401, 'UNAUTHENTICATED');
    }
    final refresh = response.refreshToken ?? previousRefresh;
    if (refresh == null || refresh.isEmpty) {
      throw const ParentApiException(401, 'UNAUTHENTICATED');
    }
    await _storage.write(key: _refreshKey, value: refresh);
    _accessToken = response.accessToken;
    _idToken = response.idToken;
    _expiresAt = response.accessTokenExpirationDateTime;
  }

  Future<void> _loadIdentity() async {
    final me = await api.object('/me');
    final workspaces = await api.all('/tenants');
    final selected = await _storage.read(key: _workspaceKey);
    Json? next;
    String nextRole = '';
    if (workspaces.isNotEmpty) {
      next = workspaces.firstWhere((item) => item['id'] == selected,
          orElse: () => workspaces.first);
      final membership = await api.object('/tenants/${next['id']}/membership');
      nextRole = membership['role'] as String? ?? '';
    }
    // Publish an identity and its membership together. A failed membership read
    // must not leave an adult profile paired with a stale workspace role.
    generation++;
    profile = me;
    tenants = workspaces;
    tenant = next;
    role = nextRole;
    notifyListeners();
  }

  Future<void> selectTenant(Json next) async {
    final id = next['id'];
    if (id is! String || !tenants.any((item) => item['id'] == id)) {
      throw const ParentApiException(403, 'SCOPE_DENIED');
    }
    final epoch = ++generation;
    final membership = await api.object('/tenants/$id/membership');
    if (epoch != generation) return;
    tenant = next;
    role = membership['role'] as String? ?? '';
    await _storage.write(key: _workspaceKey, value: id);
    notifyListeners();
  }

  Future<void> _clear() async {
    generation++;
    _accessToken = null;
    _idToken = null;
    _expiresAt = null;
    profile = null;
    tenants = const [];
    tenant = null;
    role = '';
    await _storage.delete(key: _refreshKey);
    await _storage.delete(key: _workspaceKey);
  }

  Future<void> signOut() async {
    final idToken = _idToken;
    await _clear();
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
  }

  @override
  void dispose() {
    api.close();
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
