// ignore_for_file: avoid_web_libraries_in_flutter
// Browser storage is isolated here; access tokens live only in this tab's session.
import 'dart:html' as html;
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:oauth2/oauth2.dart' as oauth;
import 'api.dart';
import 'access.dart';
import 'scoped_http_client.dart';
import 'report_job_resume.dart';
import 'contract_action_resume.dart';
import 'family_identity_controller.dart';

class Session extends ChangeNotifier {
  static const issuer = String.fromEnvironment('OIDC_ISSUER',
      defaultValue: 'http://localhost:8081/realms/ai-manager');
  static const clientId = 'ai-manager-guardian';
  oauth.Client? _client;
  Json? profile;
  List<Json> tenants = [];
  Json? tenant;
  String role = '';
  bool ready = false;
  String loginReturnPath = '/';
  Object? error;
  final _selection = SelectionGeneration();
  final _authenticationOwners = AuthenticationOwner();
  int _scopeGeneration = 0;
  int get scopeGeneration => _scopeGeneration;
  late final Api api = Api(authenticatedClient);
  bool get authenticated => _client != null && profile != null;
  bool get canWrite => ['OWNER', 'GUARDIAN', 'ORG_ADMIN'].contains(role);
  bool get canManage => ['OWNER', 'ORG_ADMIN'].contains(role);
  bool get canManageCatalog => profile?['canManageCatalog'] == true;
  bool get canApproveCatalog => profile?['canApproveCatalog'] == true;
  bool get canManageContracts => profile?['canManageContracts'] == true;
  bool get canApproveContracts => profile?['canApproveContracts'] == true;
  bool get canReviewManagedAndroid =>
      profile?['canReviewManagedAndroid'] == true;
  bool get canReviewFamilyRefunds => profile?['canReviewFamilyRefunds'] == true;
  bool get canManageFamilyFinance => profile?['canManageFamilyFinance'] == true;
  bool get canReadIdentityProviders =>
      profile?['canReadIdentityProviders'] == true;
  bool get canManageIdentityProviders =>
      profile?['canManageIdentityProviders'] == true;
  bool get canTestIdentityProviders =>
      profile?['canTestIdentityProviders'] == true;
  bool get canPublishIdentityProviders =>
      profile?['canPublishIdentityProviders'] == true;
  bool get canRollbackIdentityProviders =>
      profile?['canRollbackIdentityProviders'] == true;
  IdentityProviderOperationStorage get identityProviderOperationStorage =>
      const _IdentityProviderTabStorage();
  bool canOpen(String section) {
    if (section == 'identity-providers') {
      return canOpenIdentityProviders(
          authenticated: authenticated,
          canRead: canReadIdentityProviders,
          canManage: canManageIdentityProviders,
          canTest: canTestIdentityProviders,
          canPublish: canPublishIdentityProviders,
          canRollback: canRollbackIdentityProviders);
    }
    if (section == 'family-finance') {
      return canOpenFamilyFinance(
          authenticated: authenticated,
          canReviewRefunds: canReviewFamilyRefunds,
          canManageFinance: canManageFamilyFinance);
    }
    if (section == 'managed-android-review') {
      return authenticated && canReviewManagedAndroid;
    }
    if (section == 'managed-android') {
      return authenticated &&
          tenant?['kind'] == 'ORGANIZATION' &&
          const {'OWNER', 'ORG_ADMIN', 'AUDITOR'}.contains(role);
    }
    if (section == 'device-groups') {
      return authenticated &&
          tenant?['kind'] == 'ORGANIZATION' &&
          const {'OWNER', 'ORG_ADMIN'}.contains(role);
    }
    if (section == 'support') {
      return authenticated && (canWrite || profile?['canCreateTenant'] == true);
    }
    if (section == 'catalog') {
      return authenticated && (canManageCatalog || canApproveCatalog);
    }
    if (section == 'contracts') {
      return authenticated && (canManageContracts || canApproveContracts);
    }
    if (section == 'institution-contracts') {
      return authenticated &&
          tenant?['kind'] == 'ORGANIZATION' &&
          ['OWNER', 'ORG_ADMIN', 'AUDITOR'].contains(role);
    }
    return (section != 'classes' || tenant?['kind'] == 'ORGANIZATION') &&
        (section != 'help-requests' ||
            role != 'TEACHER' ||
            tenant?['kind'] == 'ORGANIZATION') &&
        canOpenSection(role, section);
  }

  String get root => '/tenants/${tenant!['id']}';
  String get displayName =>
      profile?['name'] as String? ?? profile?['email'] as String? ?? '管理员';
  Uri get redirect => Uri.parse('${html.window.location.origin}/auth/callback');
  void _save(oauth.Credentials credentials, Object owner) =>
      _authenticationOwners.saveIfCurrent(owner, () {
        html.window.sessionStorage['ai-manager.session'] = credentials.toJson();
      });

  bool _installClient(oauth.Client next, Object owner) {
    if (!_authenticationOwners.isCurrent(owner)) {
      next.close();
      return false;
    }
    _client?.close();
    _client = next;
    _scopeGeneration++;
    return true;
  }

  oauth.AuthorizationCodeGrant _grant(String verifier, Object owner) =>
      oauth.AuthorizationCodeGrant(
          clientId,
          Uri.parse('$issuer/protocol/openid-connect/auth'),
          Uri.parse('$issuer/protocol/openid-connect/token'),
          codeVerifier: verifier,
          basicAuth: false,
          httpClient: ScopeGuardedClient(http.Client()),
          onCredentialsRefreshed: (credentials) => _save(credentials, owner));
  Future<void> initialize() async {
    ready = false;
    error = null;
    final owner = _authenticationOwners.begin();
    _scopeGeneration++;
    _selection.invalidate();
    final previousClient = _client;
    _client = null;
    profile = null;
    tenants = [];
    tenant = null;
    role = '';
    previousClient?.close();
    notifyListeners();
    try {
      final uri = Uri.base;
      if (uri.path == '/auth/callback') {
        final stored = html.window.sessionStorage.remove('ai-manager.pkce');
        if (stored == null) throw const ApiFailure(401, 'LOGIN_STATE_EXPIRED');
        final pending = jsonDecode(stored) as Json;
        if (DateTime.now().millisecondsSinceEpoch -
                (pending['created'] as int) >
            600000) throw const ApiFailure(401, 'LOGIN_STATE_EXPIRED');
        final grant = _grant(pending['verifier'], owner);
        grant.getAuthorizationUrl(redirect,
            scopes: ['openid', 'profile', 'email', 'tenant:create'],
            state: pending['state']);
        final next = await grant
            .handleAuthorizationResponse(uri.queryParameters)
            .timeout(const Duration(seconds: 30));
        if (!_installClient(next, owner)) return;
        _save(next.credentials, owner);
        loginReturnPath = trustedReturnPath(pending['returnPath'] as String?);
        html.window.history.replaceState(null, '', loginReturnPath);
      } else {
        final saved = html.window.sessionStorage['ai-manager.session'];
        if (saved != null) {
          final next = oauth.Client(oauth.Credentials.fromJson(saved),
              identifier: clientId,
              basicAuth: false,
              httpClient: ScopeGuardedClient(http.Client()),
              onCredentialsRefreshed: (credentials) =>
                  _save(credentials, owner));
          if (!_installClient(next, owner)) return;
        }
      }
      if (_client != null) {
        final activeClient = _client!;
        final nextProfile = await api.send('GET', '/me',
            isCurrent: () =>
                _authenticationOwners.isCurrent(owner) &&
                identical(_client, activeClient)) as Json;
        if (!_authenticationOwners.isCurrent(owner)) return;
        profile = nextProfile;
        await loadTenants();
      }
    } catch (e) {
      if (!_authenticationOwners.isCurrent(owner)) return;
      error = e;
      _clear();
      ready = true;
      notifyListeners();
      return;
    }
    if (!_authenticationOwners.isCurrent(owner)) return;
    ready = true;
    notifyListeners();
  }

  Future<http.Client> authenticatedClient() async {
    if (_client == null) throw const ApiFailure(401, 'UNAUTHENTICATED');
    return _client!;
  }

  void login({bool stepUp = false}) {
    final verifier = requestId() + requestId();
    final state = requestId();
    html.window.sessionStorage['ai-manager.pkce'] = jsonEncode({
      'verifier': verifier,
      'state': state,
      'returnPath': trustedReturnPath(html.window.location.pathname),
      'created': DateTime.now().millisecondsSinceEpoch
    });
    // This grant builds a redirect URL only; it never owns a signed-in client.
    final grant = _grant(verifier, Object());
    final url = grant.getAuthorizationUrl(redirect,
        scopes: ['openid', 'profile', 'email', 'tenant:create'], state: state);
    final params = {
      ...url.queryParameters,
      'ui_locales': 'zh-CN',
      if (stepUp) 'max_age': '0'
    };
    html.window.location
        .assign(url.replace(queryParameters: params).toString());
  }

  void reauthenticateReport(ReportJobResume resume) {
    if (!authenticated || tenant == null || !canWrite) {
      throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    }
    html.window.sessionStorage['ai-manager.report-resume'] = resume.encode(
        actor: profile!['subject'],
        root: root,
        role: role,
        now: DateTime.now().millisecondsSinceEpoch);
    login(stepUp: true);
  }

  void reauthenticateContractAction(ContractActionResume resume,
      {required bool platform}) {
    final scope = platform ? 'platform' : 'tenant';
    if (!authenticated ||
        (platform
            ? !canOpen('contracts')
            : !canOpen('institution-contracts'))) {
      throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    }
    html.window.sessionStorage['ai-manager.contract-resume'] = resume.encode(
        actor: profile!['subject'],
        scope: scope,
        tenantId: platform ? '' : tenant!['id'],
        role: role,
        now: DateTime.now().millisecondsSinceEpoch);
    login(stepUp: true);
  }

  ContractActionResume? takeContractActionResume({required bool platform}) {
    final saved =
        html.window.sessionStorage.remove('ai-manager.contract-resume');
    if (!authenticated ||
        (platform
            ? !canOpen('contracts')
            : !canOpen('institution-contracts'))) {
      return null;
    }
    return ContractActionResume.decode(saved,
        actor: profile!['subject'],
        scope: platform ? 'platform' : 'tenant',
        tenantId: platform ? '' : tenant!['id'],
        role: role,
        now: DateTime.now().millisecondsSinceEpoch);
  }

  ReportJobResume? takeReportResume() {
    final saved = html.window.sessionStorage.remove('ai-manager.report-resume');
    if (!authenticated || tenant == null) return null;
    return ReportJobResume.decode(saved,
        actor: profile!['subject'],
        root: root,
        role: role,
        now: DateTime.now().millisecondsSinceEpoch);
  }

  Future<void> loadTenants({String? preferredTenantId}) async {
    final activeClient = _client;
    if (activeClient == null) throw const ApiFailure(401, 'UNAUTHENTICATED');
    final nextTenants = await api.all('/tenants',
        isCurrent: () => identical(_client, activeClient));
    if (!identical(_client, activeClient)) return;
    if (preferredTenantId != null &&
        !nextTenants.any((value) => value['id'] == preferredTenantId)) {
      throw const ApiFailure(409, 'WORKSPACE_NOT_VISIBLE');
    }
    tenants = nextTenants;
    final selected =
        preferredTenantId ?? html.window.localStorage['ai-manager.workspace'];
    if (tenants.isNotEmpty) {
      await selectTenant(tenants.firstWhere((t) => t['id'] == selected,
          orElse: () => tenants.first));
    } else {
      tenant = null;
      role = '';
      notifyListeners();
    }
  }

  Future<void> selectTenant(Json next) async {
    final activeClient = _client;
    if (activeClient == null) throw const ApiFailure(401, 'UNAUTHENTICATED');
    final generation = _selection.begin();
    _scopeGeneration++;
    notifyListeners();
    if (tenant != null && tenant!['id'] != next['id']) {
      html.window.sessionStorage.remove('ai-manager.report-resume');
      html.window.sessionStorage.remove('ai-manager.contract-resume');
    }
    late final Json membership;
    try {
      membership = await api.send('GET', '/tenants/${next['id']}/membership',
          isCurrent: () =>
              _selection.current(generation) &&
              identical(_client, activeClient)) as Json;
    } on ApiFailure {
      if (!_selection.current(generation) ||
          !identical(_client, activeClient)) {
        return;
      }
      rethrow;
    }
    if (!_selection.current(generation) || !identical(_client, activeClient)) {
      return;
    }
    tenant = next;
    role = membership['role'];
    html.window.localStorage['ai-manager.workspace'] = next['id'];
    notifyListeners();
  }

  void _clear() {
    _authenticationOwners.invalidate();
    _scopeGeneration++;
    _selection.invalidate();
    final previousClient = _client;
    _client = null;
    profile = null;
    tenants = [];
    tenant = null;
    role = '';
    previousClient?.close();
    html.window.sessionStorage.remove('ai-manager.session');
    html.window.sessionStorage.remove('ai-manager.report-resume');
    html.window.sessionStorage.remove('ai-manager.contract-resume');
  }

  void logout() {
    _clear();
    notifyListeners();
    html.window.location.assign(
        Uri.parse('$issuer/protocol/openid-connect/logout')
            .replace(queryParameters: {
      'client_id': clientId,
      'post_logout_redirect_uri': '${html.window.location.origin}/'
    }).toString());
  }

  void account() => html.window.open(
      '$issuer/account/#/account-security/signing-in', '_blank', 'noopener');
}

/// Only the core controller's UUID/type journal enters this tab-local adapter.
class _IdentityProviderTabStorage implements IdentityProviderOperationStorage {
  const _IdentityProviderTabStorage();
  @override
  String? read(String key) => html.window.sessionStorage[key];
  @override
  void write(String key, String value) =>
      html.window.sessionStorage[key] = value;
  @override
  void remove(String key) => html.window.sessionStorage.remove(key);
}
