import com.fasterxml.jackson.databind.*;
import java.net.*;
import java.net.http.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Duration;
import java.util.*;
import java.util.concurrent.*;
import java.util.regex.*;

/** Executes actual OIDC/PKCE and actual MySQL JPA; SMS and WeChat are fixture transports. */
public final class MysqlIdentityAcceptance {
  static final String ROOT="https://127.0.0.1:8443/identity/realms/ai-manager",FIXTURE=ROOT+"/mysql-acceptance-fixture/";
  static final ObjectMapper JSON=new ObjectMapper().enable(com.fasterxml.jackson.core.JsonParser.Feature.STRICT_DUPLICATE_DETECTION)
      .disable(com.fasterxml.jackson.core.JsonParser.Feature.INCLUDE_SOURCE_IN_LOCATION);
  static final List<String> PASSED=new ArrayList<>();
  static final HttpClient CONTROL=HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(3)).followRedirects(HttpClient.Redirect.NEVER).build();
  record Tokens(String access,String refresh,String subject,int revision){}
  static final class Flow {
    final String verifier=UUID.randomUUID().toString()+UUID.randomUUID().toString();
    final String state=UUID.randomUUID().toString();
    final HttpClient client=HttpClient.newBuilder().cookieHandler(new CookieManager(null,CookiePolicy.ACCEPT_ALL)).followRedirects(HttpClient.Redirect.NEVER).build();
    HttpResponse<String> response;
    Flow(Map<String,String> extra,boolean offline)throws Exception{
      var params=new LinkedHashMap<String,String>();params.put("client_id","ai-manager-parent");params.put("redirect_uri","com.aimanager.parent:/oauth2redirect");
      params.put("response_type","code");params.put("scope",offline?"openid offline_access":"openid");params.put("state",state);params.put("nonce",UUID.randomUUID().toString());
      params.put("code_challenge",Base64.getUrlEncoder().withoutPadding().encodeToString(MessageDigest.getInstance("SHA-256").digest(verifier.getBytes(StandardCharsets.US_ASCII))));
      params.put("code_challenge_method","S256");params.put("prompt","login");params.putAll(extra);
      response=request(client,ROOT+"/protocol/openid-connect/auth?"+form(params),null,null);
    }
    Flow send(String phone)throws Exception{
      json(FIXTURE+"reset/"+phone,Map.of());
      response=request(client,action(response),form(Map.of("action","send","phone",phone)),null);
      require(response.statusCode()==200&&response.body().contains("name=\"code\""),"OTP form: "+safeResponseKind(response));return this;
    }
    Flow verify(String phone)throws Exception{
      String code=json(FIXTURE+"proof/"+phone,null).path("code").asText();require(code.matches("[0-9]{6}"),"fixture proof");
      return verifyCode(code);
    }
    Flow verifyCode(String code)throws Exception{response=request(client,action(response),form(Map.of("action","verify","code",code)),null);return this;}
    Tokens tokens()throws Exception{
      require(response.statusCode()==302,"OIDC completion (HTTP "+response.statusCode()+")");
      String location=response.headers().firstValue("Location").orElse("");var query=query(URI.create(location).getRawQuery());
      require(state.equals(query.get("state"))&&query.containsKey("code"),"OIDC state/code");
      var token=request(client,ROOT+"/protocol/openid-connect/token",form(Map.of("grant_type","authorization_code","client_id","ai-manager-parent","redirect_uri","com.aimanager.parent:/oauth2redirect","code_verifier",verifier,"code",query.get("code"))),null);
      require(token.statusCode()==200,"PKCE exchange");JsonNode body=JSON.readTree(token.body());String access=body.path("access_token").asText();
      JsonNode claims=JSON.readTree(Base64.getUrlDecoder().decode(access.split("\\.")[1]));
      require(claims.path("phone_number").isTextual()&&claims.path("phone_number").asText().matches("\\+861[3-9][0-9]{9}"),"trusted phone string claim");
      require(claims.path("phone_number_verified").isBoolean()&&claims.path("phone_number_verified").asBoolean(),"trusted phone boolean claim");
      require(claims.path("consumer_identity_revision").isIntegralNumber()&&claims.path("consumer_identity_revision").asInt()>0,"trusted revision integer claim");
      require(claims.path("auth_time").isIntegralNumber()&&claims.path("auth_time").asLong()>0,"trusted auth_time integer claim");
      require(claims.path("amr").isArray()&&claims.path("amr").size()==1&&Set.of("sms","wechat").contains(claims.path("amr").get(0).asText()),"trusted amr array claim");
      return new Tokens(access,body.path("refresh_token").asText(),claims.path("sub").asText(),claims.path("consumer_identity_revision").asInt());
    }
    boolean blocked(){return response.statusCode()==200&&response.body().contains("请关闭此页，回到 App 核对当前账号状态后重新开始。")
        &&!response.body().contains("name=\"phone\"")&&!response.body().contains("name=\"code\"");}
  }
  static Flow account(String action,Tokens token,String code)throws Exception{
    var p=new LinkedHashMap<String,String>();p.put("family_account_action",action);p.put("family_account_operation",UUID.randomUUID().toString());
    if(token!=null){p.put("family_account_actor",token.subject);p.put("family_account_revision",Integer.toString(token.revision));}
    if(code!=null)p.put("family_wechat_code",code);return new Flow(p,false);
  }
  static String wechat(String owner){return "fixture_"+owner+"_"+UUID.randomUUID().toString().replace("-","");}
  static Tokens login(String phone,boolean offline)throws Exception{return new Flow(Map.of(),offline).send(phone).verify(phone).tokens();}
  static Tokens change(Tokens token,String oldPhone,String newPhone)throws Exception{return account("CHANGE_PHONE",token,null).send(oldPhone).verify(oldPhone).send(newPhone).verify(newPhone).tokens();}
  static JsonNode status(Tokens token,int expected)throws Exception{var r=request(CONTROL,ROOT+"/consumer-account/status",null,token.access);require(r.statusCode()==expected,"account current-state HTTP "+expected);require(r.headers().firstValue("Cache-Control").orElse("").contains("no-store"),"no-store current-state");return JSON.readTree(r.body());}
  static void refreshDenied(Tokens token)throws Exception{var r=request(CONTROL,ROOT+"/protocol/openid-connect/token",form(Map.of("client_id","ai-manager-parent","grant_type","refresh_token","refresh_token",token.refresh)),null);require(r.statusCode()==400,"revoked refresh rejected");}
  static JsonNode user(String phone)throws Exception{return json(FIXTURE+"user/"+phone,null);}
  static void passed(String name){PASSED.add(name);System.out.println("PASS "+name);}
  public static void main(String[] args)throws Exception{
    boolean ready=false;long readyDeadline=System.nanoTime()+Duration.ofMinutes(3).toNanos();
    while(System.nanoTime()<readyDeadline){try{var r=request(CONTROL,ROOT+"/.well-known/openid-configuration",null,null);if(r.statusCode()==200){ready=true;break;}}catch(Exception ignored){}Thread.sleep(1000);}require(ready,"new isolated identity ready");
    boolean hostnameRejected=false;try{request(CONTROL,ROOT.replace("127.0.0.1","127.0.0.2")+"/.well-known/openid-configuration",null,null);}catch(javax.net.ssl.SSLHandshakeException expected){hostnameRejected=true;}
    require(hostnameRejected,"TLS hostname mismatch must be rejected");passed("https-trusted-test-certificate-and-hostname-mismatch-rejected");
    boolean httpClosed=false;try{request(CONTROL,ROOT.replace("https://127.0.0.1:8443","http://127.0.0.1:8080")+"/.well-known/openid-configuration",null,null);}catch(java.net.ConnectException expected){httpClosed=true;}
    require(httpClosed,"plaintext HTTP listener must be closed");passed("https-only-runtime-plaintext-http-listener-closed");
    var facts=json(FIXTURE+"facts",null);require(facts.path("databaseVersion").asText().startsWith("8.4."),"real MySQL 8.4");require("REPEATABLE-READ".equals(facts.path("isolation").asText()),"MySQL RR isolation");passed("mysql84-repeatable-read");
    if(Arrays.asList(args).contains("--federated-identity-probe")){
      ExecutorService probe=Executors.newFixedThreadPool(2);boolean allCurrent=true;
      try{
        Tokens x=login("13800001032",false),y=login("13800001033",false);
        Flow left=account("BIND_WECHAT",x,wechat("competitionprobe")).send("13800001032");String leftOtp=json(FIXTURE+"proof/13800001032",null).path("code").asText();
        Flow right=account("BIND_WECHAT",y,wechat("competitionprobe")).send("13800001033");String rightOtp=json(FIXTURE+"proof/13800001033",null).path("code").asText();
        var r1=probe.submit(()->left.verifyCode(leftOtp));var r2=probe.submit(()->right.verifyCode(rightOtp));r1.get(15,TimeUnit.SECONDS);r2.get(15,TimeUnit.SECONDS);
        require(left.response.statusCode()==302&&right.blocked()||right.response.statusCode()==302&&left.blocked(),"focused openid competition has one success and one explicit rejection");
        System.out.println("DIAGNOSTIC real-oidc-openid-competition PASS; completeAcceptance=false");
        allCurrent=fidCurrentReads(probe,true);
        require(allCurrent,"focused FID current reads failed");return;
      }finally{probe.shutdownNow();}
    }
    if(Arrays.asList(args).contains("--user-row-probe")){
      login("13800001020",false);ExecutorService probe=Executors.newSingleThreadExecutor();
      try{
        var primed=probe.submit(()->json(FIXTURE+"rr-user-prime/13800001020",Map.of()));
        boolean snapshot=false;for(int i=0;i<100;i++){if(json(FIXTURE+"facts",null).path("userRrPrimed").asBoolean()){snapshot=true;break;}Thread.sleep(20);}require(snapshot,"RR user snapshot primed");
        json(FIXTURE+"rr-user-update/13800001020",Map.of());require(!user("13800001020").path("enabled").asBoolean(),"secondary user row update committed before release");json(FIXTURE+"rr-user-release",Map.of());primed.get(15,TimeUnit.SECONDS);
        System.out.println("DIAGNOSTIC locked-user-enabled-current-read PASS; completeAcceptance=false");return;
      }finally{probe.shutdownNow();}
    }
    var unauth=request(CONTROL,ROOT+"/consumer-account/status",null,null);require(unauth.statusCode()==401,"unauthenticated account status rejected");passed("production-resource-authentication-boundary");
    String a="13800001001",b="13800001002",c="13800001003";
    Tokens ta=login(a,false),tb=login(b,false),tc=login(c,false);require(ta.revision==1&&tb.revision==1,"initial revisions");status(ta,200);passed("real-oidc-pkce-phone-registration-simulated-sms");
    json(FIXTURE+"grant-offline/"+a,Map.of());Tokens offline=login(a,true);require(user(a).path("offline").asInt()==1,"offline session exists");require("Offline".equals(JSON.readTree(Base64.getUrlDecoder().decode(offline.refresh.split("\\.")[1])).path("typ").asText()),"actual offline refresh");passed("actual-online-and-offline-sessions-created");
    ta=account("BIND_WECHAT",ta,wechat("alice")).send(a).verify(a).tokens();require(ta.revision==2&&user(a).path("wechatBound").asBoolean(),"wechat linked same actor");
    status(offline,401);refreshDenied(offline);passed("binding-rotates-revision-and-revokes-old-online-offline-sessions");
    Tokens wx=new Flow(Map.of("family_wechat_code",wechat("alice")),false).tokens();require(wx.subject.equals(ta.subject)&&wx.revision==2,"linked wechat login");passed("linked-wechat-login-simulated-exchange");
    Tokens stale=new Tokens(ta.access,ta.refresh,ta.subject,1);require(account("CHANGE_PHONE",stale,null).blocked(),"stale expected revision blocked");
    var afterStale=user(a);require(afterStale.path("revision").asInt()==2&&afterStale.path("subject").asText().equals(ta.subject)&&afterStale.path("wechatBound").asBoolean(),"stale flow does not mutate identity or binding");status(ta,200);passed("stale-identity-revision-rejected");
    String original=ta.subject;Tokens changed=change(ta,a,"13800001004");require(changed.subject.equals(original)&&changed.revision==3&&!user(a).path("exists").asBoolean(),"phone rename preserves subject");status(ta,401);refreshDenied(wx);passed("phone-change-preserves-subject-removes-old-phone-and-revokes-old-session");
    Tokens recovered=account("RECOVER_PHONE",null,wechat("alice")).send("13800001005").verify("13800001005").tokens();require(recovered.subject.equals(original)&&recovered.revision==4,"wechat recovery keeps original actor");status(changed,401);passed("bound-wechat-account-recovery-preserves-subject");
    Tokens unbound=account("UNBIND_WECHAT",recovered,null).send("13800001005").verify("13800001005").tokens();require(unbound.revision==5&&!user("13800001005").path("wechatBound").asBoolean(),"unlink retains phone");status(recovered,401);
    require(account("RECOVER_PHONE",null,wechat("alice")).blocked(),"unlinked recovery denied");require(account("RECOVER_PHONE",null,wechat("unknown")).blocked(),"unknown wechat cannot create recovery account");passed("wechat-unlink-retains-phone-and-blocks-unbound-unknown-recovery");
    Tokens rebound=account("BIND_WECHAT",unbound,wechat("alice")).send("13800001005").verify("13800001005").tokens();require(rebound.subject.equals(original)&&rebound.revision==6,"rebind same actor");passed("wechat-rebind-after-unlink");
    ExecutorService pool=Executors.newFixedThreadPool(3);
    try{
      login("13800001010",false);var primed=pool.submit(()->json(FIXTURE+"rr-prime/13800001010",Map.of()));
      boolean snapshot=false;for(int i=0;i<100;i++){if(json(FIXTURE+"facts",null).path("rrPrimed").asBoolean()){snapshot=true;break;}Thread.sleep(20);}require(snapshot,"RR snapshot primed");
      json(FIXTURE+"rr-update/13800001010",Map.of());var committed=user("13800001010");require(!committed.path("enabled").asBoolean()&&committed.path("revision").asInt()==2&&committed.path("newAttributePresent").asBoolean(),"secondary user and attribute updates committed before release");json(FIXTURE+"rr-release",Map.of());primed.get(15,TimeUnit.SECONDS);passed("mysql-rr-preloaded-locked-user-sees-current-enabled-revision-and-attribute");
      login("13800001011",false);login("13800001012",false);json(FIXTURE+"pending-refresh/13800001011",Map.of());
      var actorWrites=user("13800001011");var otherWrites=user("13800001012");
      require(actorWrites.path("pendingBefore").asBoolean()&&actorWrites.path("pendingAfter").asBoolean()&&otherWrites.path("unrelatedBefore").asBoolean()&&otherWrites.path("unrelatedAfter").asBoolean(),"actor and unrelated before/after writes all survive commit");passed("refresh-preserves-existing-model-references-and-pending-writes");
      require(fidCurrentReads(pool,false),"both FID reads must use the latest committed identity after an RR snapshot");
      var hold=pool.submit(()->json(FIXTURE+"hold?milliseconds=1400&rollback=true",Map.of()));waitHolding();long start=System.nanoTime();
      var wait=pool.submit(()->json(FIXTURE+"hold?milliseconds=0",Map.of()));hold.get(15,TimeUnit.SECONDS);wait.get(15,TimeUnit.SECONDS);
      require((System.nanoTime()-start)/1_000_000>=900&&user("13800001005").path("rollbackAbsent").asBoolean(),"pessimistic lock waits and rollback releases");passed("real-pessimistic-realm-lock-wait-and-rollback-release");
      Flow fb=account("CHANGE_PHONE",tb,null).send(b).verify(b).send("13800001006");String codeB=json(FIXTURE+"proof/13800001006",null).path("code").asText();
      Flow fc=account("CHANGE_PHONE",tc,null).send(c).verify(c).send("13800001006");String codeC=json(FIXTURE+"proof/13800001006",null).path("code").asText();
      var rb=pool.submit(()->fb.verifyCode(codeB));var rc=pool.submit(()->fc.verifyCode(codeC));rb.get(15,TimeUnit.SECONDS);rc.get(15,TimeUnit.SECONDS);
      require(fb.response.statusCode()==302&&fc.blocked()||fc.response.statusCode()==302&&fb.blocked(),"concurrent target phone exactly one success and one recoverable rejection");
      String bp=fb.response.statusCode()==302?"13800001006":b,cp=fc.response.statusCode()==302?"13800001006":c;
      tb=fb.response.statusCode()==302?fb.tokens():tb;tc=fc.response.statusCode()==302?fc.tokens():tc;
      require(user("13800001006").path("exists").asBoolean()&&(!user(b).path("exists").asBoolean()^!user(c).path("exists").asBoolean()),"single phone owner");passed("concurrent-two-actors-same-phone-exactly-one-commits");
      Flow wb=account("BIND_WECHAT",tb,wechat("shared")).send(bp);String otpB=json(FIXTURE+"proof/"+bp,null).path("code").asText();
      Flow wc=account("BIND_WECHAT",tc,wechat("shared")).send(cp);String otpC=json(FIXTURE+"proof/"+cp,null).path("code").asText();
      var w1=pool.submit(()->wb.verifyCode(otpB));var w2=pool.submit(()->wc.verifyCode(otpC));w1.get(15,TimeUnit.SECONDS);w2.get(15,TimeUnit.SECONDS);
      require(wb.response.statusCode()==302&&wc.blocked()||wc.response.statusCode()==302&&wb.blocked(),"concurrent openid exactly one success and one recoverable rejection");require(user(bp).path("wechatBound").asBoolean()^user(cp).path("wechatBound").asBoolean(),"single openid owner");passed("concurrent-two-actors-same-openid-exactly-one-commits");
      Tokens td=login("13800001007",false);Flow d1=account("CHANGE_PHONE",td,null).send("13800001007").verify("13800001007").send("13800001008");String q1=json(FIXTURE+"proof/13800001008",null).path("code").asText();
      Flow d2=account("CHANGE_PHONE",td,null).send("13800001007").verify("13800001007").send("13800001009");String q2=json(FIXTURE+"proof/13800001009",null).path("code").asText();
      var p1=pool.submit(()->d1.verifyCode(q1));var p2=pool.submit(()->d2.verifyCode(q2));p1.get(15,TimeUnit.SECONDS);p2.get(15,TimeUnit.SECONDS);
      require(d1.response.statusCode()==302&&d2.blocked()||d2.response.statusCode()==302&&d1.blocked(),"same actor exactly one change and one recoverable stale rejection");
      var finalUser=user(d1.response.statusCode()==302?"13800001008":"13800001009");require(finalUser.path("revision").asInt()==2&&finalUser.path("subject").asText().equals(td.subject),"revision cannot roll back");passed("concurrent-same-actor-stale-version-cannot-overwrite");
    }finally{pool.shutdownNow();}
    var summary=new LinkedHashMap<String,Object>();summary.put("passed",PASSED);summary.put("count",PASSED.size());summary.put("realMysqlAcceptance",true);summary.put("realOidcPkce",true);summary.put("realSupplierAcceptance",false);summary.put("smsTransport","private fixture");summary.put("wechatTransport","private fixture");summary.put("salesEnabled",false);summary.put("strictJwtPayloadParsing",true);summary.put("trustedClaimTypesVerified",true);
    System.out.println("EVIDENCE "+JSON.writeValueAsString(summary));
  }
  static boolean fidCurrentReads(ExecutorService pool,boolean diagnostic)throws Exception{
    boolean allCurrent=true;
    for(String mode:List.of("owner","actor")){
      String phone=mode.equals("owner")?"13800001030":"13800001031",round=UUID.randomUUID().toString().replace("-","");Tokens actor=login(phone,false);
      var primed=pool.submit(()->json(FIXTURE+"fid-prime/"+mode+"/"+phone+"/"+round,Map.of()));
      boolean snapshot=false;for(int i=0;i<100;i++){if(json(FIXTURE+"fid-ready/"+round,null).path("primed").asBoolean()){snapshot=true;break;}Thread.sleep(20);}require(snapshot,"independent FID snapshot primed");
      account("BIND_WECHAT",actor,wechat(mode+"probe")).send(phone).verify(phone).tokens();require(user(phone).path("wechatBound").asBoolean(),"FID binding committed before release");
      json(FIXTURE+"fid-release/"+round,Map.of());boolean current=true;try{primed.get(15,TimeUnit.SECONDS);}catch(ExecutionException expected){current=false;}
      allCurrent&=current;
      if(diagnostic)System.out.println("DIAGNOSTIC "+mode+"-fid-current-read "+(current?"PASS":"FAIL")+"; completeAcceptance=false");
      else{require(current,mode+" FID current read must complete without a server error");passed("mysql-rr-"+mode+"-federated-identity-current-read-after-committed-link");}
    }
    return allCurrent;
  }
  static void waitHolding()throws Exception{for(int i=0;i<60;i++){if(json(FIXTURE+"facts",null).path("holding").asBoolean())return;Thread.sleep(40);}throw new AssertionError("lock holder ready");}
  static JsonNode json(String url,Map<String,String> post)throws Exception{var r=request(CONTROL,url,post==null?null:form(post),null);require(r.statusCode()==200,"fixture control HTTP "+r.statusCode());return JSON.readTree(r.body());}
  static HttpResponse<String> request(HttpClient client,String url,String post,String bearer)throws Exception{var b=HttpRequest.newBuilder(URI.create(url)).timeout(Duration.ofSeconds(12));if(bearer!=null)b.header("Authorization","Bearer "+bearer);if(post!=null)b.header("Content-Type","application/x-www-form-urlencoded").POST(HttpRequest.BodyPublishers.ofString(post));else b.GET();return client.send(b.build(),HttpResponse.BodyHandlers.ofString());}
  static String action(HttpResponse<String> response){var m=Pattern.compile("<form[^>]*action=\"([^\"]+)\"").matcher(response.body());require(m.find(),"expected authentication form (HTTP "+response.statusCode()+")");String url=m.group(1).replace("&amp;","&");require(URI.create(url).getPath().equals("/identity/realms/ai-manager/login-actions/authenticate"),"unexpected form action path: "+URI.create(url).getPath());return url;}
  static String safeResponseKind(HttpResponse<String> response){
    // Emit only fixed error labels, never response HTML, codes, tokens, phone numbers or action URLs.
    String body=response.body();var labels=new ArrayList<String>();
    for(String label:List.of("发送较频繁","请输入正确的中国大陆手机号","短信暂时发送失败","登录配置未就绪","手机号服务暂未开放","Invalid username","Invalid code","Page has expired"))if(body.contains(label))labels.add(label);
    return "HTTP "+response.statusCode()+", labels="+labels+", phoneInput="+body.contains("name=\"phone\"")+", codeInput="+body.contains("name=\"code\"");
  }
  static String form(Map<String,String> p){return p.entrySet().stream().map(e->encode(e.getKey())+"="+encode(e.getValue())).reduce((a,b)->a+"&"+b).orElse("");}
  static String encode(String s){return URLEncoder.encode(s,StandardCharsets.UTF_8);}
  static Map<String,String> query(String q){var p=new HashMap<String,String>();for(String pair:q.split("&")){String[] a=pair.split("=",2);p.put(URLDecoder.decode(a[0],StandardCharsets.UTF_8),URLDecoder.decode(a[1],StandardCharsets.UTF_8));}return p;}
  static void require(boolean ok,String name){if(!ok)throw new AssertionError(name);}
}
