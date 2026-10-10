// ignore_for_file: avoid_web_libraries_in_flutter
// Browser storage is isolated here; access tokens live only in this tab's session.
import 'dart:html' as html;
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:oauth2/oauth2.dart' as oauth;
import 'api.dart';
import 'access.dart';
import 'report_job_resume.dart';

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
  late final Api api = Api(authenticatedClient);
  bool get authenticated => _client != null && profile != null;
  bool get canWrite => ['OWNER', 'GUARDIAN', 'ORG_ADMIN'].contains(role);
  bool get canManage => ['OWNER', 'ORG_ADMIN'].contains(role);
  bool get canManageCatalog => profile?['canManageCatalog'] == true;
  bool get canApproveCatalog => profile?['canApproveCatalog'] == true;
  bool canOpen(String section) => section == 'support'
      ? authenticated && (canWrite || profile?['canCreateTenant'] == true)
      : section == 'catalog'
          ? authenticated && (canManageCatalog || canApproveCatalog)
          : (section != 'classes' || tenant?['kind'] == 'ORGANIZATION') &&
              canOpenSection(role, section);
  String get root => '/tenants/${tenant!['id']}';
  String get displayName =>
      profile?['name'] as String? ?? profile?['email'] as String? ?? '管理员';
  Uri get redirect => Uri.parse('${html.window.location.origin}/auth/callback');
  void _save(oauth.Credentials credentials) =>
      html.window.sessionStorage['ai-manager.session'] = credentials.toJson();
  oauth.AuthorizationCodeGrant _grant(String verifier) =>
      oauth.AuthorizationCodeGrant(
          clientId,
          Uri.parse('$issuer/protocol/openid-connect/auth'),
          Uri.parse('$issuer/protocol/openid-connect/token'),
          codeVerifier: verifier,
          basicAuth: false,
          onCredentialsRefreshed: _save);
  Future<void> initialize() async {
    ready = false;
    error = null;
    try {
      final uri = Uri.base;
      if (uri.path == '/auth/callback') {
        final stored = html.window.sessionStorage.remove('ai-manager.pkce');
        if (stored == null) throw const ApiFailure(401, 'LOGIN_STATE_EXPIRED');
        final pending = jsonDecode(stored) as Json;
        if (DateTime.now().millisecondsSinceEpoch -
                (pending['created'] as int) >
            600000) throw const ApiFailure(401, 'LOGIN_STATE_EXPIRED');
        final grant = _grant(pending['verifier']);
        grant.getAuthorizationUrl(redirect,
            scopes: ['openid', 'profile', 'email', 'tenant:create'],
            state: pending['state']);
        _client = await grant
            .handleAuthorizationResponse(uri.queryParameters)
            .timeout(const Duration(seconds: 30));
        _save(_client!.credentials);
        loginReturnPath = trustedReturnPath(pending['returnPath'] as String?);
        html.window.history.replaceState(null, '', loginReturnPath);
      } else {
        final saved = html.window.sessionStorage['ai-manager.session'];
        if (saved != null) {
          _client = oauth.Client(oauth.Credentials.fromJson(saved),
              identifier: clientId,
              basicAuth: false,
              onCredentialsRefreshed: _save);
        }
      }
      if (_client != null) {
        profile = await api.send('GET', '/me') as Json;
        await loadTenants();
      }
    } catch (e) {
      error = e;
      _clear();
    }
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
    final grant = _grant(verifier);
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

  ReportJobResume? takeReportResume() {
    final saved = html.window.sessionStorage.remove('ai-manager.report-resume');
    if (!authenticated || tenant == null) return null;
    return ReportJobResume.decode(saved,
        actor: profile!['subject'],
        root: root,
        role: role,
        now: DateTime.now().millisecondsSinceEpoch);
  }

  Future<void> loadTenants() async {
    tenants = await api.all('/tenants');
    final selected = html.window.localStorage['ai-manager.workspace'];
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
    if (tenant != null && tenant!['id'] != next['id']) {
      html.window.sessionStorage.remove('ai-manager.report-resume');
    }
    final generation = _selection.begin();
    final membership =
        await api.send('GET', '/tenants/${next['id']}/membership') as Json;
    if (!_selection.current(generation)) return;
    tenant = next;
    role = membership['role'];
    html.window.localStorage['ai-manager.workspace'] = next['id'];
    notifyListeners();
  }

  void _clear() {
    _selection.invalidate();
    _client?.close();
    _client = null;
    profile = null;
    tenants = [];
    tenant = null;
    role = '';
    html.window.sessionStorage.remove('ai-manager.session');
    html.window.sessionStorage.remove('ai-manager.report-resume');
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
