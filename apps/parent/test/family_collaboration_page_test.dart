import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/family_collaboration.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/ui/family_members_page.dart';
import 'package:parent/ui/family_invitation_page.dart';
import 'package:parent/ui/family_workspace.dart';
import 'family_collaboration_test.dart'
    show familyId, invitationId, secret, summary, response;
import 'family_device_access_test.dart' show SelectionMemoryStorage;
import 'family_workspace_test.dart' show FamilySession;

class CollaborationSession extends FamilySession {
  int refreshed = 0, selected = 0;
  bool failRefresh = false, swapActorDuringRefresh = false;
  CollaborationSession(super.api,
      {String currentRole = 'OWNER', bool noFamily = false}) {
    tenant =
        noFamily ? null : {'id': familyId, 'kind': 'FAMILY', 'name': '我的家庭'};
    tenants = tenant == null ? [] : [tenant!];
    role = noFamily ? '' : currentRole;
  }
  @override
  Future<void> refreshWorkspaces() async {
    refreshed++;
    generation++;
    if (swapActorDuringRefresh) {
      profile = {'subject': 'another-adult', 'name': '另一账号'};
    }
    tenants = [
      {'id': familyId, 'kind': 'FAMILY', 'name': '家人的家庭'}
    ];
    notifyListeners();
    if (failRefresh) throw const ParentApiException(503, 'UNAVAILABLE');
  }

  @override
  Future<void> selectTenant(Json next) async {
    selected++;
    generation++;
    tenant = next;
    role = 'GUARDIAN';
    notifyListeners();
  }
}

Json members({String role = 'OWNER', bool declaration = false}) => {
      'tenantId': familyId,
      'currentRole': role,
      'guardianDeclarationRequired': declaration,
      'members': [
        {
          'memberKey': 'a' * 64,
          'displayName': role == 'OWNER' ? '我' : '家庭创建者',
          'role': 'OWNER',
          'version': 0,
          'self': role == 'OWNER',
          'canRemove': false
        },
        {
          'memberKey': 'b' * 64,
          'displayName': role == 'GUARDIAN' ? '我' : '共同监护人',
          'role': 'GUARDIAN',
          'version': 0,
          'self': role == 'GUARDIAN',
          'canRemove': role == 'OWNER'
        }
      ]
    };
Future<void> openMembers(WidgetTester tester, CollaborationSession session,
    SelectionMemoryStorage store,
    {double scale = 1}) async {
  await tester.pumpWidget(MaterialApp(
      theme: familyTheme(),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: FamilyMembersPage(session: session, storage: store)));
  await tester.pumpAndSettle();
}

Future<void> openAcceptance(WidgetTester tester, CollaborationSession session,
    SelectionMemoryStorage store,
    {FamilyInvitationIntent? initial}) async {
  await tester.pumpWidget(MaterialApp(
      theme: familyTheme(),
      home: FamilyInvitationAcceptancePage(
          session: session, storage: store, initialIntent: initial)));
  await tester.pumpAndSettle();
}

Future<void> createInvite(WidgetTester tester) async {
  await tester.enterText(
      find.byKey(const ValueKey('family-invite-phone')), '13900000000');
  await tester.ensureVisible(find.text('生成邀请链接'));
  await tester.tap(find.text('生成邀请链接'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('local family collaboration previews contain fictional data only',
      (tester) async {
    const directory = String.fromEnvironment('FAMILY_COLLAB_CAPTURE');
    if (directory.isEmpty) return;
    await tester.runAsync(() async {
      await (FontLoader('Roboto')
            ..addFont(Future.value(ByteData.sublistView(
                await File('C:/Windows/Fonts/msyh.ttc').readAsBytes()))))
          .load();
      await (FontLoader('MaterialIcons')
            ..addFont(Future.value(ByteData.sublistView(await File(
                    'D:/softwares/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')
                .readAsBytes()))))
          .load();
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final page in ['family-members', 'family-invitation']) {
      final session = CollaborationSession(
          ParentApi(() async => 'fixture', baseUrl: 'https://fixture.invalid',
              client: MockClient((r) async {
            if (r.url.path.endsWith('/family-members')) {
              return response(members());
            }
            if (r.url.path.endsWith('/preview')) {
              return response({
                'invitationId': invitationId,
                'tenantId': familyId,
                'tenantName': '家人的家庭',
                'role': 'GUARDIAN',
                'expiresAt': 1800000000000,
                'state': 'PENDING'
              });
            }
            return response({'tenantId': familyId, 'items': []});
          })),
          noFamily: page == 'family-invitation');
      final boundary = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
          key: boundary,
          child: MaterialApp(
              theme: familyTheme(),
              debugShowCheckedModeBanner: false,
              builder: (context, child) => Column(children: [
                    const Material(
                        color: Color(0xFFFFF3D6),
                        child: SizedBox(
                            width: double.infinity,
                            child: Padding(
                                padding: EdgeInsets.all(6),
                                child: Text('布局预览 · 样例数据',
                                    textAlign: TextAlign.center)))),
                    Expanded(child: child!)
                  ]),
              home: page == 'family-members'
                  ? FamilyMembersPage(
                      session: session, storage: SelectionMemoryStorage())
                  : FamilyInvitationAcceptancePage(
                      session: session,
                      storage: SelectionMemoryStorage(),
                      initialIntent:
                          FamilyInvitationIntent(invitationId, secret)))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final render = boundary.currentContext!.findRenderObject()
            as RenderRepaintBoundary;
        final frame = await render.toImage(pixelRatio: 1);
        final bytes = await frame.toByteData(format: ui.ImageByteFormat.png);
        await File('$directory/$page.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        frame.dispose();
      });
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    }
  });
  testWidgets(
      'owner creates an invitation and explicitly copies a private share link',
      (tester) async {
    final calls = <http.Request>[];
    String? copied;
    Json? issued;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'];
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final session = CollaborationSession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.url.path.endsWith('/family-members')) return response(members());
      if (r.method == 'POST') {
        calls.add(r);
        issued = summary((jsonDecode(r.body) as Json)['invitationId']);
        return response(issued!, 201);
      }
      return response({
        'tenantId': familyId,
        'items': issued == null ? [] : [issued!]
      });
    })));
    addTearDown(session.dispose);
    await openMembers(tester, session, SelectionMemoryStorage());
    await createInvite(tester);
    expect(calls, hasLength(1));
    expect(find.text('邀请已准备好'), findsOneWidget);
    await tester.ensureVisible(find.text('复制邀请链接'));
    await tester.tap(find.text('复制邀请链接'));
    await tester.pumpAndSettle();
    expect(copied, isNotNull);
    expect(copied, isNot(contains('13900000000')));
    expect(FamilyInvitationIntent.parse(copied!).id,
        (jsonDecode(calls.single.body) as Json)['invitationId']);
  });
  testWidgets(
      'unknown issuance is recovered by explicit same-request retry and reads never resend',
      (tester) async {
    final calls = <http.Request>[];
    var lose = true;
    final session = CollaborationSession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.url.path.endsWith('/family-members')) return response(members());
      if (r.method == 'POST') {
        calls.add(r);
        return lose
            ? response({'errorCode': 'UNAVAILABLE'}, 503)
            : response(
                summary((jsonDecode(r.body) as Json)['invitationId']), 201);
      }
      return response({'tenantId': familyId, 'items': []});
    })));
    addTearDown(session.dispose);
    final store = SelectionMemoryStorage();
    await openMembers(tester, session, store);
    await createInvite(tester);
    await tester.pumpWidget(const SizedBox());
    await openMembers(tester, session, store);
    expect(find.text('上次邀请待核对'), findsOneWidget);
    await tester.ensureVisible(find.text('查询邀请状态'));
    await tester.tap(find.text('查询邀请状态'));
    await tester.pumpAndSettle();
    expect(calls, hasLength(1));
    lose = false;
    await tester.ensureVisible(find.text('继续核对原邀请'));
    await tester.tap(find.text('继续核对原邀请'));
    await tester.pumpAndSettle();
    expect(calls, hasLength(2));
    expect(calls.last.body, calls.first.body);
    expect(calls.last.headers['Idempotency-Key'],
        calls.first.headers['Idempotency-Key']);
  });
  testWidgets(
      'guardian sees family adults without creation or removal controls',
      (tester) async {
    final session = CollaborationSession(
        ParentApi(() async => 'fixture',
            baseUrl: 'https://fixture.invalid',
            client: MockClient((r) async => response(
                r.url.path.endsWith('/family-members')
                    ? members(role: 'GUARDIAN')
                    : {'tenantId': familyId, 'items': []}))),
        currentRole: 'GUARDIAN');
    addTearDown(session.dispose);
    await openMembers(tester, session, SelectionMemoryStorage());
    expect(find.text('家庭创建者'), findsWidgets);
    expect(find.byKey(const ValueKey('family-invite-phone')), findsNothing);
    expect(find.text('生成邀请链接'), findsNothing);
    expect(find.text('移除'), findsNothing);
  });
  testWidgets(
      'joining without an existing family requires an explicit adult declaration',
      (tester) async {
    var accepts = 0;
    final session = CollaborationSession(
        ParentApi(() async => 'fixture', baseUrl: 'https://fixture.invalid',
            client: MockClient((r) async {
          if (r.url.path.endsWith('/preview')) {
            return response({
              'invitationId': invitationId,
              'tenantId': familyId,
              'tenantName': '家人的家庭',
              'role': 'GUARDIAN',
              'expiresAt': 1800000000000,
              'state': 'PENDING'
            });
          }
          accepts++;
          return response({
            'invitationId': invitationId,
            'tenantId': familyId,
            'role': 'GUARDIAN',
            'memberVersion': 0,
            'currentState': 'ACTIVE'
          });
        })),
        noFamily: true);
    addTearDown(session.dispose);
    await openAcceptance(tester, session, SelectionMemoryStorage(),
        initial: FamilyInvitationIntent(invitationId, secret));
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '加入家庭'))
            .onPressed,
        isNull);
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('加入家庭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入家庭'));
    await tester.pumpAndSettle();
    expect(accepts, 1);
    expect(session.refreshed, 1);
    expect(session.selected, 1);
    expect(find.textContaining('已加入家庭'), findsOneWidget);
  });
  testWidgets('unknown join resumes the original request after reopening',
      (tester) async {
    final calls = <http.Request>[];
    var lose = true;
    final session = CollaborationSession(
        ParentApi(() async => 'fixture', baseUrl: 'https://fixture.invalid',
            client: MockClient((r) async {
          if (r.url.path.endsWith('/preview')) {
            return response({
              'invitationId': invitationId,
              'tenantId': familyId,
              'tenantName': '家人的家庭',
              'role': 'GUARDIAN',
              'expiresAt': 1800000000000,
              'state': 'PENDING'
            });
          }
          calls.add(r);
          return lose
              ? response({'errorCode': 'UNAVAILABLE'}, 503)
              : response({
                  'invitationId': invitationId,
                  'tenantId': familyId,
                  'role': 'GUARDIAN',
                  'memberVersion': 0,
                  'currentState': 'ACTIVE'
                });
        })),
        noFamily: true);
    addTearDown(session.dispose);
    final store = SelectionMemoryStorage();
    await openAcceptance(tester, session, store,
        initial: FamilyInvitationIntent(invitationId, secret));
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('加入家庭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入家庭'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await openAcceptance(tester, session, store);
    expect(find.text('上次加入待核对'), findsOneWidget);
    lose = false;
    await tester.ensureVisible(find.text('继续核对原加入'));
    await tester.tap(find.text('继续核对原加入'));
    await tester.pumpAndSettle();
    expect(calls, hasLength(2));
    expect(calls.last.body, calls.first.body);
    expect(calls.last.headers['Idempotency-Key'],
        calls.first.headers['Idempotency-Key']);
  });
  testWidgets(
      'background dismisses an old removal dialog and changed family never revives it',
      (tester) async {
    var deletes = 0;
    final session = CollaborationSession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.method == 'DELETE') deletes++;
      return response(r.url.path.endsWith('/family-members')
          ? members()
          : {'tenantId': familyId, 'items': []});
    })));
    addTearDown(session.dispose);
    await openMembers(tester, session, SelectionMemoryStorage());
    await tester.ensureVisible(find.text('移除'));
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();
    expect(find.text('确认移除'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(find.text('确认移除'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    session.leaveAndReturn();
    await tester.pumpAndSettle();
    expect(deletes, 0);
    expect(find.text('共同监护人'), findsNothing);
    expect(find.textContaining('当前家庭或权限已变化'), findsOneWidget);
  });
  testWidgets(
      'legacy adult declaration is explicit and saved before issuing an invitation',
      (tester) async {
    final order = <String>[];
    var declared = false;
    Json? issued;
    final session = CollaborationSession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.url.path.endsWith('/family-members')) {
        return response(members(declaration: !declared));
      }
      if (r.method == 'POST' &&
          r.url.path.endsWith('/family-guardian-declaration')) {
        order.add('declare');
        declared = true;
        expect(jsonDecode(r.body), {
          'adultGuardian': true,
          'declarationVersion': 'family-guardian-v1'
        });
        return response({
          'declarationVersion': 'family-guardian-v1',
          'declaredAt': 1800000000000
        });
      }
      if (r.method == 'POST') {
        order.add('invite');
        issued = summary((jsonDecode(r.body) as Json)['invitationId']);
        return response(issued!, 201);
      }
      return response({
        'tenantId': familyId,
        'items': issued == null ? [] : [issued!]
      });
    })));
    addTearDown(session.dispose);
    await openMembers(tester, session, SelectionMemoryStorage());
    await tester.scrollUntilVisible(find.byType(CheckboxListTile), 250,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '生成邀请链接'))
            .onPressed,
        isNull);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await createInvite(tester);
    expect(order, ['declare', 'invite']);
  });
  testWidgets(
      'failed clipboard write is recoverable and does not create another invitation',
      (tester) async {
    var posts = 0;
    Json? issued;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        throw PlatformException(code: 'unavailable');
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final session = CollaborationSession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.url.path.endsWith('/family-members')) return response(members());
      if (r.method == 'POST') {
        posts++;
        issued = summary((jsonDecode(r.body) as Json)['invitationId']);
        return response(issued!, 201);
      }
      return response({
        'tenantId': familyId,
        'items': issued == null ? [] : [issued!]
      });
    })));
    addTearDown(session.dispose);
    await openMembers(tester, session, SelectionMemoryStorage());
    await createInvite(tester);
    await tester.ensureVisible(find.text('复制邀请链接'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制邀请链接'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('暂时无法复制'), findsOneWidget);
    expect(posts, 1);
  });
  testWidgets(
      'unknown member removal only retries the original target and version',
      (tester) async {
    final deletes = <http.Request>[];
    var lose = true, removed = false;
    final session = CollaborationSession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.method == 'DELETE') {
        deletes.add(r);
        if (lose) return response({'errorCode': 'UNAVAILABLE'}, 503);
        removed = true;
        return http.Response('', 204);
      }
      if (r.url.path.endsWith('/family-members')) {
        final value = members();
        if (removed) (value['members'] as List).removeLast();
        return response(value);
      }
      return response({'tenantId': familyId, 'items': []});
    })));
    addTearDown(session.dispose);
    final store = SelectionMemoryStorage();
    await openMembers(tester, session, store);
    await tester.ensureVisible(find.text('移除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认移除'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await openMembers(tester, session, store);
    expect(find.text('上次家庭操作待核对'), findsOneWidget);
    await tester.ensureVisible(find.text('查询家庭状态'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查询家庭状态'));
    await tester.pumpAndSettle();
    expect(deletes, hasLength(1));
    lose = false;
    await tester.ensureVisible(find.text('继续核对原操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续核对原操作'));
    await tester.pumpAndSettle();
    expect(deletes, hasLength(2));
    expect(deletes.last.url, deletes.first.url);
    expect(deletes.last.headers['Idempotency-Key'],
        deletes.first.headers['Idempotency-Key']);
    expect(deletes.last.headers['If-Match'], deletes.first.headers['If-Match']);
  });
  testWidgets(
      'a delayed preview never reveals the previous account family after switching accounts',
      (tester) async {
    final reply = Completer<http.Response>();
    final session = CollaborationSession(
        ParentApi(() async => 'fixture',
            baseUrl: 'https://fixture.invalid',
            client: MockClient((r) => reply.future)),
        noFamily: true);
    addTearDown(session.dispose);
    await tester.pumpWidget(MaterialApp(
        theme: familyTheme(),
        home: FamilyInvitationAcceptancePage(
            session: session,
            storage: SelectionMemoryStorage(),
            initialIntent: FamilyInvitationIntent(invitationId, secret))));
    await tester.pump();
    session.profile = {'subject': 'another-adult', 'name': '另一账号'};
    session.notifyListeners();
    reply.complete(response({
      'invitationId': invitationId,
      'tenantId': familyId,
      'tenantName': '家人的家庭',
      'role': 'GUARDIAN',
      'expiresAt': 1800000000000,
      'state': 'PENDING'
    }));
    await tester.pumpAndSettle();
    expect(find.text('家人的家庭'), findsNothing);
    expect(find.text('加入家庭'), findsNothing);
    expect(find.textContaining('账号或登录状态已变化'), findsOneWidget);
  });
  testWidgets(
      'refresh failure can be retried without accepting twice and another account is never selected',
      (tester) async {
    var posts = 0;
    final session = CollaborationSession(
        ParentApi(() async => 'fixture', baseUrl: 'https://fixture.invalid',
            client: MockClient((r) async {
          if (r.url.path.endsWith('/preview')) {
            return response({
              'invitationId': invitationId,
              'tenantId': familyId,
              'tenantName': '家人的家庭',
              'role': 'GUARDIAN',
              'expiresAt': 1800000000000,
              'state': 'PENDING'
            });
          }
          posts++;
          return response({
            'invitationId': invitationId,
            'tenantId': familyId,
            'role': 'GUARDIAN',
            'memberVersion': 0,
            'currentState': 'ACTIVE'
          });
        })),
        noFamily: true)
      ..failRefresh = true;
    addTearDown(session.dispose);
    await openAcceptance(tester, session, SelectionMemoryStorage(),
        initial: FamilyInvitationIntent(invitationId, secret));
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('加入家庭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入家庭'));
    await tester.pumpAndSettle();
    expect(posts, 1);
    expect(find.text('刷新家庭列表'), findsOneWidget);
    session.failRefresh = false;
    session.swapActorDuringRefresh = true;
    await tester.ensureVisible(find.text('刷新家庭列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('刷新家庭列表'));
    await tester.pumpAndSettle();
    expect(posts, 1);
    expect(session.selected, 0);
    expect(find.textContaining('账号或登录状态已变化'), findsOneWidget);
  });
  testWidgets(
      'server-side removal hides previously visible members after refresh',
      (tester) async {
    var removed = false;
    final session = CollaborationSession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.url.path.endsWith('/family-members')) {
        return removed
            ? response({'errorCode': 'SCOPE_DENIED'}, 403)
            : response(members());
      }
      return response({'tenantId': familyId, 'items': []});
    })));
    addTearDown(session.dispose);
    await openMembers(tester, session, SelectionMemoryStorage());
    expect(find.text('共同监护人'), findsOneWidget);
    removed = true;
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(find.text('共同监护人'), findsNothing);
    expect(find.byKey(const ValueKey('family-invite-phone')), findsNothing);
    expect(find.text('重新读取家庭成员'), findsOneWidget);
  });
  testWidgets(
      'editing a link invalidates the old family preview and adult confirmation',
      (tester) async {
    var accepts = 0;
    final session = CollaborationSession(
        ParentApi(() async => 'fixture', baseUrl: 'https://fixture.invalid',
            client: MockClient((r) async {
          if (r.url.path.endsWith('/preview')) {
            return response({
              'invitationId': invitationId,
              'tenantId': familyId,
              'tenantName': '家人的家庭',
              'role': 'GUARDIAN',
              'expiresAt': 1800000000000,
              'state': 'PENDING'
            });
          }
          accepts++;
          return response({});
        })),
        noFamily: true);
    addTearDown(session.dispose);
    await openAcceptance(tester, session, SelectionMemoryStorage(),
        initial: FamilyInvitationIntent(invitationId, secret));
    await tester
        .ensureVisible(find.byKey(const ValueKey('family-invitation-link')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('family-invitation-link')),
        FamilyInvitationIntent('cccccccc-cccc-4ccc-8ccc-cccccccccccc', secret)
            .link);
    await tester.pumpAndSettle();
    expect(find.text('家人的家庭'), findsNothing);
    expect(find.text('加入家庭'), findsNothing);
    expect(accepts, 0);
  });
  testWidgets(
      'narrow large-font family collaboration remains scrollable without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = CollaborationSession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid',
        client: MockClient((r) async => response(
            r.url.path.endsWith('/family-members')
                ? members(declaration: true)
                : {'tenantId': familyId, 'items': []}))));
    addTearDown(session.dispose);
    await openMembers(tester, session, SelectionMemoryStorage(), scale: 2);
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('family-invite-phone')), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
