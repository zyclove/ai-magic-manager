package com.aimanager.identity;

import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import java.util.List;
import org.keycloak.connections.jpa.JpaConnectionProvider;
import org.keycloak.models.*;
import org.keycloak.models.jpa.entities.UserEntity;
import org.keycloak.models.jpa.entities.UserAttributeEntity;

/** 首发以 realm 数据库行锁串行化短身份事务，缓存租约不承担账号唯一性。 */
final class ConsumerIdentityTransactions {
  // 绑定已验收的 Keycloak 26.8 / MySQL 表结构；原生锁定投影不经过旧 RR 快照和一级缓存。
  private static final String CURRENT_USER_SQL="select ID, USERNAME, FIRST_NAME, CREATED_TIMESTAMP, LAST_MODIFIED_TIMESTAMP, LAST_NAME, EMAIL, ENABLED, EMAIL_VERIFIED, EMAIL_CONSTRAINT, REALM_ID, FEDERATION_LINK, SERVICE_ACCOUNT_CLIENT_LINK, NOT_BEFORE from USER_ENTITY where ID = :actor and REALM_ID = :realm for update";
  private static final String CURRENT_ATTRIBUTE_IDS_SQL="select ID from USER_ATTRIBUTE where USER_ID = :actor order by ID for update";
  private static final String CURRENT_WECHAT_COLUMNS="select USER_ID, REALM_ID, IDENTITY_PROVIDER, FEDERATED_USER_ID, FEDERATED_USERNAME from FEDERATED_IDENTITY where REALM_ID = :realm and IDENTITY_PROVIDER = :provider";
  private ConsumerIdentityTransactions(){}
  static void lockRealm(KeycloakSession session,RealmModel realm){
    try{
      var em=entityManager(session);
      Object row=em.createQuery("select r from RealmEntity r where r.id = :realmId").setParameter("realmId",realm.getId()).setLockMode(LockModeType.PESSIMISTIC_WRITE).setHint("jakarta.persistence.lock.timeout",3000).getSingleResult();
      if(row==null)throw new IllegalStateException("Consumer identity storage is unavailable");
    }catch(RuntimeException failure){session.getTransactionManager().setRollbackOnly();throw new IllegalStateException("Consumer identity transaction is unavailable");}
  }
  static UserModel refreshUser(KeycloakSession session,RealmModel realm,UserModel user){
    if(user==null)return null;
    var em=entityManager(session);UserEntity entity=em.find(UserEntity.class,user.getId());
    if(entity==null)throw new IllegalStateException("Consumer identity storage is unavailable");
    // 保留同事务已提交给持久化上下文的修改，不清除用户、realm 或已有 adapter 引用。
    em.flush();
    loadCurrentUserScalars(em,realm,entity);
    var rows=em.createNativeQuery(CURRENT_ATTRIBUTE_IDS_SQL).setParameter("actor",user.getId()).getResultList();
    var attributes=new java.util.ArrayList<UserAttributeEntity>();
    for(Object row:rows){
      if(!(row instanceof String id)||id.isBlank())throw new IllegalStateException("Consumer identity storage is unavailable");
      // 已持锁实体的 refresh 可能降为普通 SELECT；只脱离此属性，再强制当前锁定读取。
      em.detach(em.getReference(UserAttributeEntity.class,id));
      var attribute=em.find(UserAttributeEntity.class,id,LockModeType.PESSIMISTIC_WRITE);
      if(attribute==null||attribute.getUser()==null||!entity.getId().equals(attribute.getUser().getId()))throw new IllegalStateException("Consumer identity storage is unavailable");
      attributes.add(attribute);
    }
    var managedAttributes=entity.getAttributes();managedAttributes.clear();managedAttributes.addAll(attributes);
    return ConsumerIdentity.currentUsers(session).getUserById(realm,user.getId());
  }
  private static void loadCurrentUserScalars(EntityManager em,RealmModel realm,UserEntity entity){
    var rows=em.createNativeQuery(CURRENT_USER_SQL).setParameter("actor",entity.getId()).setParameter("realm",realm.getId()).getResultList();
    if(rows.size()!=1||!(rows.get(0) instanceof Object[] row)||row.length!=14)throw new IllegalStateException("Consumer identity storage is unavailable");
    var current=new CurrentUser(databaseText(row[0],false),databaseText(row[1],false),databaseText(row[2],true),databaseLong(row[3]),databaseLong(row[4]),databaseText(row[5],true),databaseText(row[6],true),databaseBoolean(row[7]),databaseBoolean(row[8]),databaseText(row[9],true),databaseText(row[10],false),databaseText(row[11],true),databaseText(row[12],true),databaseInt(row[13]));
    if(!entity.getId().equals(current.id())||!realm.getId().equals(current.realmId()))throw new IllegalStateException("Consumer identity storage is unavailable");
    // 同步全部基础列，防止后续整行 UPDATE 把旧快照中的其它列写回；用户实例始终保持附着。
    entity.setUsername(current.username());entity.setFirstName(current.firstName());entity.setCreatedTimestamp(current.createdTimestamp());entity.setLastModifiedTimestamp(current.lastModifiedTimestamp());entity.setLastName(current.lastName());
    entity.setEmail(current.email(),true);entity.setEmailConstraint(current.emailConstraint());
    entity.setEnabled(current.enabled());entity.setEmailVerified(current.emailVerified());entity.setRealmId(current.realmId());entity.setFederationLink(current.federationLink());entity.setServiceAccountClientLink(current.serviceAccountClientLink());entity.setNotBefore(current.notBefore());
  }
  private static String databaseText(Object value,boolean nullable){
    if(value==null&&nullable)return null;
    if(value instanceof String text&&(nullable||!text.isBlank()))return text;
    throw new IllegalStateException("Consumer identity storage is unavailable");
  }
  private static Long databaseLong(Object value){
    if(value==null)return null;
    if(value instanceof Byte||value instanceof Short||value instanceof Integer||value instanceof Long)return ((Number)value).longValue();
    try{
      if(value instanceof java.math.BigInteger integer)return integer.longValueExact();
      if(value instanceof java.math.BigDecimal decimal)return decimal.longValueExact();
    }catch(ArithmeticException failure){throw new IllegalStateException("Consumer identity storage is unavailable");}
    throw new IllegalStateException("Consumer identity storage is unavailable");
  }
  private static int databaseInt(Object value){
    Long number=databaseLong(value);
    if(number==null||number<Integer.MIN_VALUE||number>Integer.MAX_VALUE)throw new IllegalStateException("Consumer identity storage is unavailable");
    return number.intValue();
  }
  private static boolean databaseBoolean(Object value){
    if(value instanceof Boolean flag)return flag;
    Long number=databaseLong(value);
    if(number!=null&&(number==0||number==1))return number==1;
    throw new IllegalStateException("Consumer identity storage is unavailable");
  }
  private record CurrentUser(String id,String username,String firstName,Long createdTimestamp,Long lastModifiedTimestamp,String lastName,String email,boolean enabled,boolean emailVerified,String emailConstraint,String realmId,String federationLink,String serviceAccountClientLink,int notBefore){}
  static UserModel byUsername(KeycloakSession session,RealmModel realm,String username){
    var rows=entityManager(session).createQuery("select u from UserEntity u where u.realmId = :realmId and u.username = :username").setParameter("realmId",realm.getId()).setParameter("username",username).setLockMode(LockModeType.PESSIMISTIC_WRITE).getResultList();
    if(rows.size()>1)throw new IllegalStateException("Consumer phone identity is not unique");if(rows.isEmpty())return null;
    return refreshUser(session,realm,ConsumerIdentity.currentUsers(session).getUserById(realm,((UserEntity)rows.get(0)).getId()));
  }
  static UserModel byWechat(KeycloakSession session,RealmModel realm,String appId,String openId){
    var em=entityManager(session);em.flush();String provider="wechat-native:"+appId;
    var rows=em.createNativeQuery(CURRENT_WECHAT_COLUMNS+" and FEDERATED_USER_ID = :openId for update").setParameter("realm",realm.getId()).setParameter("provider",provider).setParameter("openId",openId).getResultList();
    var current=currentWechat(rows,realm.getId(),provider);
    if(current==null)return null;
    if(!current.openId().equals(openId))throw new IllegalStateException("Consumer identity storage is unavailable");
    return refreshUser(session,realm,ConsumerIdentity.currentUsers(session).getUserById(realm,current.actor()));
  }
  static FederatedIdentityModel wechatForUser(KeycloakSession session,RealmModel realm,UserModel user,String appId){
    var em=entityManager(session);em.flush();String provider="wechat-native:"+appId;
    var rows=em.createNativeQuery(CURRENT_WECHAT_COLUMNS+" and USER_ID = :actor for update").setParameter("realm",realm.getId()).setParameter("provider",provider).setParameter("actor",user.getId()).getResultList();
    var current=currentWechat(rows,realm.getId(),provider);
    if(current==null)return null;
    if(!current.actor().equals(user.getId()))throw new IllegalStateException("Consumer identity storage is unavailable");
    return new FederatedIdentityModel(current.provider(),current.openId(),current.userName());
  }
  // 实体 refresh 即使标注写锁，也可能因已持锁而回退普通 RR SELECT；这里只读取锁定标量事实。
  private static CurrentWechat currentWechat(List<?> rows,String realm,String provider){
    if(rows.size()>1)throw new IllegalStateException("Consumer WeChat identity is not unique");if(rows.isEmpty())return null;
    if(!(rows.get(0) instanceof Object[] row)||row.length!=5)throw new IllegalStateException("Consumer identity storage is unavailable");
    var current=new CurrentWechat(databaseText(row[0],false),databaseText(row[1],false),databaseText(row[2],false),databaseText(row[3],false),databaseText(row[4],true));
    if(!realm.equals(current.realm())||!provider.equals(current.provider()))throw new IllegalStateException("Consumer identity storage is unavailable");
    return current;
  }
  private record CurrentWechat(String actor,String realm,String provider,String openId,String userName){}
  static void linkWechat(KeycloakSession session,RealmModel realm,UserModel user,String appId,String openId){
    UserModel owner=byWechat(session,realm,appId,openId);var existing=wechatForUser(session,realm,user,appId);
    if(owner!=null&&!owner.getId().equals(user.getId())||existing!=null&&!existing.getUserId().equals(openId))throw new ConsumerIdentity.LinkConflict();
    if(existing==null)session.users().addFederatedIdentity(realm,user,ConsumerIdentity.wechatIdentity(appId,openId));
  }
  private static EntityManager entityManager(KeycloakSession session){var provider=session.getProvider(JpaConnectionProvider.class);if(provider==null||provider.getEntityManager()==null)throw new IllegalStateException("Consumer identity storage is unavailable");return provider.getEntityManager();}
}
