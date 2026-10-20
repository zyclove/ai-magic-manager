// Production repository against a new loopback backend. All identity/provider inputs are fixtures.
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/family_identity_repository.dart';

class _FixtureTokenClient extends http.BaseClient {
  final http.Client delegate=http.Client();
  final String token;
  _FixtureTokenClient(this.token);
  @override Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['Authorization']='Bearer $token'; return delegate.send(request);
  }
  @override void close()=>delegate.close();
}
/// The request reaches the real server; only its already committed reply is discarded.
class _DropCommittedReplyClient extends http.BaseClient {
  final http.Client delegate;
  final String expectedId;
  int posts=0;
  bool committedReplyDropped=false;
  _DropCommittedReplyClient(this.delegate,this.expectedId);
  @override Future<http.StreamedResponse> send(http.BaseRequest request)async {
    _require(request.method=='POST' && request.url.path.endsWith('/identity-providers/versions') &&
      request is http.Request && (jsonDecode(request.body) as Json)['id']==expectedId);
    posts++;
    final reply=await delegate.send(request);
    await reply.stream.drain<void>();
    _require(reply.statusCode==200);
    committedReplyDropped=true;
    throw http.ClientException('Intentional test reply loss.');
  }
  @override void close() {} // The main fixture owns the shared real client.
}
void _require(bool valid) { if(!valid) throw StateError('Production HTTP assertion failed.'); }
Future<void> _denied(Future<Object?> Function() action,int status)async {
  try { await action();throw StateError('Expected a rejected operation.'); }
  on ApiFailure catch(failure) { _require(failure.status==status); }
}
Future<void> main()async {
  final clients=<_FixtureTokenClient>[];
  var count=0;
  try {
    final raw=Platform.environment['IDENTITY_PROVIDER_HTTP_FIXTURE'];
    _require(raw!=null && raw.length<16384);
    final fixture=jsonDecode(raw!) as Json,uri=Uri.parse(fixture['apiRoot'] as String);
    _require(fixture['testOnly']==true && uri.scheme=='http' && uri.host=='127.0.0.1' &&
      uri.port>1024 && uri.path=='/api/v1' && uri.userInfo.isEmpty && !uri.hasQuery && !uri.hasFragment);
    FamilyIdentityRepository repository(String key) {
      final token=fixture[key] as String;
      _require(RegExp(r'^provider-(admin|weak|family)-[0-9a-f-]{36}$').hasMatch(token));
      final client=_FixtureTokenClient(token);clients.add(client);
      return FamilyIdentityRepository(api:Api(()async=>client,baseUrl:uri.toString()),current:()=>true);
    }
    final admin=repository('adminBearer'),weak=repository('weakBearer'),family=repository('familyBearer');
    final initial=await admin.status();_require(initial.latestVersion==0 && initial.version==null && initial.environmentId=='isolated-http');count++;
    await _denied(weak.status,401);count++;
    await _denied(family.status,403);count++;
    const settings=IdentityProviderSettings(smsSignName:'家庭服务',smsTemplateCode:'SMS_123456',
      wechatAppId:'wx0123456789abcdef',parentPackageName:'com.aimanager.parent',
      parentCertificateSha256:'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
    final firstId=const Uuid().v4();
    final first=await admin.saveVersion(firstId,0,settings,replacements:{
      'smsAccessKeyId':'LTAIProviderFixture123456','smsAccessKeySecret':'ProviderFixtureSecret123456789',
      'wechatAppSecret':'abcdef0123456789abcdef0123456789'});
    _require(first.id==firstId && first.version==1 && first.baseVersion==0);count++;
    _require(first.credentials.otpHmacKey && first.credentials.smsAccessKeyId && first.credentials.smsAccessKeySecret && first.credentials.wechatAppSecret);count++;
    _require((await admin.version(firstId)).id==firstId);count++;
    _require((await admin.status()).latestVersion==1);count++;
    final validation=await admin.validate(firstId);_require(validation.readinessStatus=='READY' && validation.checks.every((check)=>check.status=='READY'));count++;
    await _denied(()=>admin.saveVersion(const Uuid().v4(),0,settings),412);count++;
    final secondId=const Uuid().v4();final second=await admin.saveVersion(secondId,1,settings);
    _require(second.id==secondId && second.version==2 && second.baseVersion==1);count++;
    _require(second.credentials.smsAccessKeySecret && second.credentials.wechatAppSecret);count++;
    _require((await admin.version(secondId)).id==secondId);count++;
    final preparationId=const Uuid().v4(),prepared=await admin.prepareRelease(preparationId,secondId);
    _require(prepared.id==preparationId && prepared.status=='PREPARED');count++;
    _require((await admin.releasePreparation(preparationId)).versionId==secondId);count++;
    final runId=const Uuid().v4(),run=await admin.startAcceptance(runId,secondId,'isolated-http','a'*64,'b'*64);
    _require(run.id==runId && run.versionId==secondId);count++;
    _require((await admin.acceptanceRun(runId)).id==runId);count++;
    _require(run.checks.length==12 && run.checks.every((check)=>check.status!='READY'));count++;
    await _denied(()=>weak.validate(secondId),401);count++;
    final lostId=const Uuid().v4(),drop=_DropCommittedReplyClient(clients.first,lostId);
    final lost=FamilyIdentityRepository(api:Api(()async=>drop,baseUrl:uri.toString()),current:()=>true);
    await _denied(()=>lost.saveVersion(lostId,2,settings),0);
    _require(drop.committedReplyDropped && drop.posts==1);count++;
    final recovered=await admin.version(lostId);
    _require(recovered.id==lostId && recovered.version==3 && recovered.credentials.smsAccessKeySecret);count++;
    _require((await admin.status()).latestVersion==3 && drop.posts==1);count++;
    final forbidden=await clients.first.post(Uri.parse('$uri/platform/identity-providers/acceptance-runs/$runId/checks/REAL_SMS_DELIVERY'),
      headers:{'Content-Type':'application/json'},body:jsonEncode({'status':'PASS'}));
    _require(forbidden.statusCode==404);count++;
    _require(count==22);
    stdout.writeln('Provider administrator production HTTP checks passed: 22');
  } catch(_) { stderr.writeln('Provider administrator production HTTP check failed after $count completed checks.');exitCode=1; }
  finally { for(final client in clients) { client.close(); } }
}
