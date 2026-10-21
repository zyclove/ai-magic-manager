package com.aimanager.commerce.internal;
import com.aimanager.identity.*;
import com.aimanager.shared.*;
import java.time.Clock;
import java.util.*;
import org.springframework.http.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.*;

/** Price approval never bypasses payment, tested device or sales readiness gates. */
@RestController
@RequestMapping("/api/v1/platform/family-subscription/catalog")
class FamilyProductCatalogController {
  private final JdbcTemplate jdbc;private final RecentAuthentication recent;private final Clock clock;
  FamilyProductCatalogController(JdbcTemplate jdbc,RecentAuthentication recent,Clock clock){this.jdbc=jdbc;this.recent=recent;this.clock=clock;}
  record Price(int priceMinor){}
  @GetMapping ResponseEntity<?> read(Authentication authentication){
    scope(authentication,"catalog:manage","catalog:approve");return response(Map.of("items",jdbc.queryForList("SELECT plan_key,version,price_minor,proposed_price,proposed_version FROM family_product_offers ORDER BY plan_key")));
  }
  @PostMapping("/{plan}/revisions")
  @Transactional(timeout=10)
  ResponseEntity<?> propose(@AuthenticationPrincipal Jwt actor,Authentication authentication,@PathVariable String plan,@RequestHeader("If-Match")String version,@RequestBody Price price){
    scope(authentication,"catalog:manage");recent.require(actor);
    if(price.priceMinor()<1||price.priceMinor()>1000000)throw DomainException.invalid("INVALID_FAMILY_PRICE");
    var row=read(plan);ResourceVersions.check(ResourceVersions.require(version),((Number)row.get("version")).longValue());
    if(row.get("proposed_version")!=null)throw new DomainException(HttpStatus.CONFLICT,"CATALOG_REVISION_PENDING");
    long next=((Number)row.get("version")).longValue()+1;
    jdbc.update("UPDATE family_product_offers SET proposed_price=?,proposed_version=?,proposed_actor=? WHERE plan_key=?",price.priceMinor(),next,ActorKeys.key(actor.getSubject()),plan);
    event(plan,next,"PROPOSED",price.priceMinor(),actor.getSubject());return response(Map.of("planKey",plan,"proposedVersion",next));
  }
  @PostMapping("/{plan}/approvals")
  @Transactional(timeout=10)
  ResponseEntity<?> approve(@AuthenticationPrincipal Jwt actor,Authentication authentication,@PathVariable String plan,@RequestHeader("If-Match")String version){
    scope(authentication,"catalog:approve");recent.require(actor);var row=read(plan);
    if(row.get("proposed_version")==null)throw DomainException.invalid("CATALOG_REVISION_REQUIRED");
    long next=((Number)row.get("proposed_version")).longValue();ResourceVersions.check(ResourceVersions.require(version),next);
    if(ActorKeys.key(actor.getSubject()).equals(row.get("proposed_actor")))throw DomainException.denied();
    int amount=((Number)row.get("proposed_price")).intValue();
    jdbc.update("UPDATE family_product_offers SET version=?,price_minor=?,proposed_price=NULL,proposed_version=NULL,proposed_actor=NULL WHERE plan_key=?",next,amount,plan);
    event(plan,next,"APPROVED",amount,actor.getSubject());return response(Map.of("planKey",plan,"offerVersion",next,"priceMinor",amount));
  }
  private Map<String,Object> read(String plan){var rows=jdbc.queryForList("SELECT * FROM family_product_offers WHERE plan_key=? FOR UPDATE",plan);if(rows.size()!=1)throw DomainException.invalid("INVALID_FAMILY_PLAN");return rows.get(0);}
  private void event(String plan,long version,String operation,int amount,String actor){jdbc.update("INSERT INTO family_product_offer_events(id,plan_key,version,operation,price_minor,actor_key,occurred_at) VALUES(?,?,?,?,?,?,?)",UUID.randomUUID().toString(),plan,version,operation,amount,ActorKeys.key(actor),clock.millis());}
  private void scope(Authentication authentication,String... allowed){if(Arrays.stream(allowed).noneMatch(s->authentication.getAuthorities().stream().anyMatch(a->a.getAuthority().equals("SCOPE_"+s))))throw DomainException.denied();}
  private ResponseEntity<?> response(Object body){return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(body);}
}
