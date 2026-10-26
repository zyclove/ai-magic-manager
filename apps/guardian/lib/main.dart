import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'core/console_routes.dart';
import 'core/session.dart';
import 'ui/design.dart';
import 'ui/login_view.dart';
import 'ui/shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  final session = Session();
  runApp(
      ChangeNotifierProvider.value(value: session, child: const GuardianApp()));
  session.initialize();
}

class GuardianApp extends StatefulWidget {
  const GuardianApp({super.key});
  @override
  State<GuardianApp> createState() => _GuardianAppState();
}

class _GuardianAppState extends State<GuardianApp> {
  late final router = GoRouter(
      refreshListenable: context.read<Session>(),
      redirect: (_, state) {
        final session = context.read<Session>();
        return state.uri.path == '/auth/callback' &&
                session.ready &&
                session.authenticated
            ? session.loginReturnPath
            : null;
      },
      routes: [
        GoRoute(path: '/', builder: (_, __) => const Entry('overview')),
        GoRoute(
            path: '/auth/callback',
            builder: (_, __) => const Entry('overview')),
        GoRoute(
            path: '/:section',
            builder: (_, s) => Entry(s.pathParameters['section']!,
                listView: consoleListViewFor(s.pathParameters['section']!, s.uri)))
      ],
      errorBuilder: (_, __) => const Entry('overview'));
  @override
  Widget build(BuildContext context) => MaterialApp.router(
      title: '智能管家 · 管理工作台',
      debugShowCheckedModeBanner: false,
      theme: consoleTheme(),
      routerConfig: router,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates);
}

class Entry extends StatelessWidget {
  final String section;
  final ConsoleListView listView;
  const Entry(this.section, {super.key, this.listView = ConsoleListView.automatic});
  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    if (!session.ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!session.authenticated) return const LoginPage();
    return ConsoleShell(section: section, listView: listView);
  }
}

class LoginPage extends StatelessWidget {
  const LoginPage({super.key});
  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    return LoginView(onLogin: () => session.login(), error: session.error);
  }
}
