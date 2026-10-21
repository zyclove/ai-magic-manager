package com.aimanager.identity;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityNotFoundException;
import jakarta.persistence.LockModeType;
import jakarta.persistence.Query;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.Test;
import org.keycloak.connections.jpa.JpaConnectionProvider;
import org.keycloak.models.*;
import org.keycloak.models.jpa.UserAdapter;
import org.keycloak.models.jpa.entities.FederatedIdentityEntity;
import org.keycloak.models.jpa.entities.UserAttributeEntity;
import org.keycloak.models.jpa.entities.UserEntity;

class ConsumerIdentityTransactionsTest {
  @Test void deletedSnapshotAttributeIsNotRefreshedAndNewCurrentAttributeIsVisible() {
    var fixture = new Fixture();
    fixture.legacyRows = List.of(fixture.deletedSnapshot);
    var current = assertDoesNotThrow(() -> fixture.reload());
    assertEquals("2", current.getFirstAttribute("consumer_identity_revision"));
    assertEquals("present-after-snapshot", current.getFirstAttribute("fixture_new_attribute"));
    assertFalse(fixture.entity.getAttributes().stream()
        .anyMatch(attribute -> attribute.getId().equals("deleted-snapshot")));
  }

  @Test void refreshPreservesTheManagedCollectionAndExistingUserAdapter() {
    var fixture = new Fixture();
    var current = fixture.reload();
    assertSame(fixture.originalWrapper, fixture.entity.getAttributes());
    assertSame(fixture.entity, ((UserAdapter) current).getEntity());
    assertEquals("2", fixture.originalAdapter.getFirstAttribute("consumer_identity_revision"));
    verify(fixture.em, never()).clear();
    verify(fixture.em, never()).detach(fixture.entity);
  }

  @Test void pendingAttributeAndUnrelatedEntityChangesAreFlushedBeforeReload() {
    var fixture = new Fixture();
    fixture.currentRevision.setValue("3");
    fixture.otherEntity.setFirstName("pending-other-name");
    var current = fixture.reload();
    assertEquals("3", current.getFirstAttribute("consumer_identity_revision"));
    assertEquals("pending-other-name", fixture.persistedOtherName.get());
    assertSame(fixture.originalWrapper, fixture.entity.getAttributes());
    verify(fixture.em, never()).clear();
    verify(fixture.em, never()).detach(fixture.otherEntity);
  }

  @Test void missingLockedAttributeFailsClosedInsteadOfSilentlyDiscardingIt() {
    var fixture = new Fixture();
    fixture.currentIds.add("missing-current-row");
    assertThrows(IllegalStateException.class, fixture::reload);
  }

  @Test void alreadyLockedUserUsesAllCurrentScalarsWithoutDetachingExistingAdapters() {
    var fixture = new Fixture();
    fixture.currentUserRow[1] = "current-username";
    fixture.currentUserRow[7] = 0;
    fixture.currentUserRow[8] = 1L;
    var current = fixture.reload();
    assertFalse(current.isEnabled());
    assertEquals("current-username", fixture.originalAdapter.getUsername());
    assertSame(fixture.entity, ((UserAdapter) current).getEntity());
    assertEquals("current-first", fixture.entity.getFirstName());
    assertEquals("current-last", fixture.entity.getLastName());
    assertEquals(100L, fixture.entity.getCreatedTimestamp());
    assertEquals(200L, fixture.entity.getLastModifiedTimestamp());
    assertEquals("current@example.invalid", fixture.entity.getEmail());
    assertTrue(fixture.entity.isEmailVerified());
    assertEquals("preserved-current-constraint", fixture.entity.getEmailConstraint());
    assertEquals("realm-a", fixture.entity.getRealmId());
    assertEquals("current-federation", fixture.entity.getFederationLink());
    assertEquals("current-service-account", fixture.entity.getServiceAccountClientLink());
    assertEquals(7, fixture.entity.getNotBefore());
    verify(fixture.em, never()).detach(fixture.entity);
  }

  @Test void nullableEmailAndTimestampsPreserveTheExactCurrentConstraint() {
    var fixture = new Fixture();
    fixture.currentUserRow[3] = null;
    fixture.currentUserRow[4] = null;
    fixture.currentUserRow[6] = null;
    fixture.currentUserRow[9] = "existing-null-email-constraint";
    fixture.reload();
    assertNull(fixture.entity.getCreatedTimestamp());
    assertNull(fixture.entity.getLastModifiedTimestamp());
    assertNull(fixture.entity.getEmail());
    assertEquals("existing-null-email-constraint", fixture.entity.getEmailConstraint());
  }

  @Test void invalidCurrentScalarTypesFailClosedWithoutCoercingThem() {
    for (Object invalidBoolean : List.of("true", 2, 0.5)) {
      var fixture = new Fixture();
      fixture.currentUserRow[7] = invalidBoolean;
      assertThrows(IllegalStateException.class, fixture::reload);
    }
    var fixture = new Fixture();
    fixture.currentUserRow[13] = Long.MAX_VALUE;
    assertThrows(IllegalStateException.class, fixture::reload);
  }

  @Test void currentUserProjectionCannotChangeTheActorOrRealm() {
    var otherActor = new Fixture();
    otherActor.currentUserRow[0] = "other-actor";
    assertThrows(IllegalStateException.class, otherActor::reload);
    var otherRealm = new Fixture();
    otherRealm.currentUserRow[10] = "other-realm";
    assertThrows(IllegalStateException.class, otherRealm::reload);
  }

  @Test void wechatOwnerUsesCurrentLockedFactsWithoutRefreshingAnInvisibleSnapshotEntity() {
    var fixture = new WechatFixture();
    assertEquals("actor", assertDoesNotThrow(() -> ConsumerIdentityTransactions.byWechat(
        fixture.user.session, fixture.user.realm, "app-a", "openid-current")).getId());
    assertEquals("openid-current", fixture.parameters.get("openId"));
    fixture.assertCurrentRead();
  }

  @Test void wechatForUserUsesCurrentLockedFactsAfterTheSnapshotPredatesTheLink() {
    var fixture = new WechatFixture();
    var link = assertDoesNotThrow(() -> ConsumerIdentityTransactions.wechatForUser(
        fixture.user.session, fixture.user.realm, fixture.user.originalAdapter, "app-a"));
    assertEquals("wechat-native:app-a", link.getIdentityProvider());
    assertEquals("openid-current", link.getUserId());
    assertEquals("current-wechat-name", link.getUserName());
    assertEquals("actor", fixture.parameters.get("actor"));
    fixture.assertCurrentRead();
  }

  @Test void removedWechatLinkDoesNotReappearFromTheFirstLevelSnapshot() {
    var fixture = new WechatFixture();
    fixture.rows = List.of();
    assertNull(ConsumerIdentityTransactions.byWechat(fixture.user.session, fixture.user.realm,
        "app-a", "openid-current"));
    assertNull(ConsumerIdentityTransactions.wechatForUser(fixture.user.session, fixture.user.realm,
        fixture.user.originalAdapter, "app-a"));
    fixture.assertCurrentRead();
  }

  @Test void duplicateCurrentWechatLinksFailClosed() {
    var fixture = new WechatFixture();
    fixture.rows = List.of(fixture.currentRow, fixture.currentRow);
    assertThrows(IllegalStateException.class, () -> ConsumerIdentityTransactions.byWechat(
        fixture.user.session, fixture.user.realm, "app-a", "openid-current"));
    assertThrows(IllegalStateException.class, () -> ConsumerIdentityTransactions.wechatForUser(
        fixture.user.session, fixture.user.realm, fixture.user.originalAdapter, "app-a"));
  }

  @Test void currentWechatProjectionMustMatchItsLookupScope() {
    for (int index : List.of(0, 1, 2, 3)) {
      var fixture = new WechatFixture();
      fixture.currentRow[index] = "other-scope";
      if (index != 0) assertThrows(IllegalStateException.class,
          () -> ConsumerIdentityTransactions.byWechat(fixture.user.session, fixture.user.realm,
              "app-a", "openid-current"));
      if (index != 3) assertThrows(IllegalStateException.class,
          () -> ConsumerIdentityTransactions.wechatForUser(fixture.user.session, fixture.user.realm,
              fixture.user.originalAdapter, "app-a"));
    }
    var fixture = new WechatFixture();
    fixture.currentRow[3] = 123L;
    assertThrows(IllegalStateException.class, () -> ConsumerIdentityTransactions.wechatForUser(
        fixture.user.session, fixture.user.realm, fixture.user.originalAdapter, "app-a"));
  }

  private static final class WechatFixture {
    final Fixture user = new Fixture();
    final Map<String, Object> parameters = new HashMap<>();
    final Object[] currentRow = {"actor", "realm-a", "wechat-native:app-a", "openid-current", "current-wechat-name"};
    List<?> rows = Collections.singletonList(currentRow);
    String sql;

    WechatFixture() {
      var stale = new FederatedIdentityEntity();
      stale.setUser(user.entity);stale.setRealmId("realm-a");
      stale.setIdentityProvider("wechat-native:app-a");stale.setUserId("openid-snapshot");
      stale.setUserName("snapshot-name");
      var legacyQuery = mock(Query.class, RETURNS_SELF);
      when(legacyQuery.getResultList()).thenReturn(List.of(stale));
      when(user.em.createQuery(startsWith("select f"))).thenReturn(legacyQuery);
      doThrow(new EntityNotFoundException("The ordinary RR refresh cannot see the new link"))
          .when(user.em).refresh(isA(FederatedIdentityEntity.class), eq(LockModeType.PESSIMISTIC_WRITE));
      var currentQuery = mock(Query.class, RETURNS_SELF);
      when(currentQuery.setParameter(anyString(), any())).thenAnswer(call -> {
        parameters.put(call.getArgument(0), call.getArgument(1));return currentQuery;
      });
      when(currentQuery.getResultList()).thenAnswer(call -> rows);
      when(user.em.createNativeQuery(contains("FEDERATED_IDENTITY"))).thenAnswer(call -> {
        sql = call.getArgument(0);return currentQuery;
      });
    }

    void assertCurrentRead() {
      assertNotNull(sql);
      assertTrue(sql.toLowerCase(java.util.Locale.ROOT).endsWith("for update"));
      assertEquals("realm-a", parameters.get("realm"));
      assertEquals("wechat-native:app-a", parameters.get("provider"));
      verify(user.em, atLeastOnce()).flush();
      verify(user.em, never()).refresh(isA(FederatedIdentityEntity.class), any(LockModeType.class));
      verify(user.em, never()).clear();
    }
  }

  private static final class Fixture {
    final KeycloakSession session = mock(KeycloakSession.class);
    final RealmModel realm = mock(RealmModel.class);
    final UserProvider users = mock(UserProvider.class);
    final EntityManager em = mock(EntityManager.class);
    final UserEntity entity = new UserEntity();
    final UserEntity otherEntity = new UserEntity();
    final AtomicReference<String> persistedOtherName = new AtomicReference<>("stored-other-name");
    final UserAttributeEntity deletedSnapshot;
    final UserAttributeEntity currentRevision;
    final UserAttributeEntity currentNew;
    final Collection<UserAttributeEntity> originalWrapper;
    final UserAdapter originalAdapter;
    final Map<String, String> databaseValues = new HashMap<>();
    final Map<String, String> databaseNames = new HashMap<>();
    final Map<String, UserAttributeEntity> managedAttributes = new HashMap<>();
    final List<String> currentIds = new ArrayList<>();
    final Object[] currentUserRow = {"actor", "cn-phone-+8613800138000", "current-first", 100L, 200L,
        "current-last", "current@example.invalid", true, true, "preserved-current-constraint", "realm-a",
        "current-federation", "current-service-account", 7};
    List<UserAttributeEntity> legacyRows;

    Fixture() {
      entity.setId("actor");
      entity.setRealmId("realm-a");
      entity.setUsername("cn-phone-+8613800138000");
      entity.setEnabled(true);
      otherEntity.setId("other-actor");
      otherEntity.setFirstName("stored-other-name");
      deletedSnapshot = attribute("deleted-snapshot", "consumer_identity_revision", "1");
      currentRevision = attribute("current-revision", "consumer_identity_revision", "2");
      currentNew = attribute("current-new", "fixture_new_attribute", "present-after-snapshot");
      originalWrapper = new ArrayList<>(List.of(deletedSnapshot));
      entity.setAttributes(originalWrapper);
      for (var attribute : List.of(currentRevision, currentNew)) {
        currentIds.add(attribute.getId());
        databaseValues.put(attribute.getId(), attribute.getValue());
        databaseNames.put(attribute.getId(), attribute.getName());
        managedAttributes.put(attribute.getId(), attribute);
      }
      legacyRows = List.of(currentRevision, currentNew);
      originalAdapter = new UserAdapter(session, realm, em, entity);
      var jpa = mock(JpaConnectionProvider.class);
      when(session.getProvider(JpaConnectionProvider.class)).thenReturn(jpa);
      when(jpa.getEntityManager()).thenReturn(em);
      when(session.getProvider(UserProvider.class, "jpa")).thenReturn(users);
      when(realm.getId()).thenReturn("realm-a");
      when(users.getUserById(realm, "actor")).thenAnswer(call -> new UserAdapter(session, realm, em, entity));
      when(em.find(UserEntity.class, "actor")).thenReturn(entity);
      var oldQuery = mock(Query.class, RETURNS_SELF);
      when(em.createQuery(anyString())).thenReturn(oldQuery);
      when(oldQuery.getResultList()).thenAnswer(call -> legacyRows);
      var currentIdsQuery = mock(Query.class, RETURNS_SELF);
      var currentUserQuery = mock(Query.class, RETURNS_SELF);
      when(em.createNativeQuery(anyString())).thenAnswer(call ->
          ((String) call.getArgument(0)).contains("USER_ENTITY") ? currentUserQuery : currentIdsQuery);
      when(currentIdsQuery.getResultList()).thenAnswer(call -> currentIds);
      when(currentUserQuery.getResultList()).thenAnswer(call -> Collections.singletonList(currentUserRow));
      when(em.getReference(eq(UserAttributeEntity.class), any())).thenAnswer(call -> {
        String id = call.getArgument(1);
        return managedAttributes.computeIfAbsent(id,
            key -> attribute(key, databaseNames.get(key), databaseValues.get(key)));
      });
      when(em.find(eq(UserAttributeEntity.class), any(), eq(LockModeType.PESSIMISTIC_WRITE)))
          .thenAnswer(call -> {
            String id = call.getArgument(1);
            return databaseValues.containsKey(id) ? attribute(id, databaseNames.get(id), databaseValues.get(id)) : null;
          });
      doAnswer(call -> {
        Object refreshed = call.getArgument(0);
        if (refreshed instanceof UserAttributeEntity attribute) {
          if (!databaseValues.containsKey(attribute.getId())) {
            throw new EntityNotFoundException("Deleted snapshot row");
          }
          attribute.setValue(databaseValues.get(attribute.getId()));
        }
        return null;
      }).when(em).refresh(any(), eq(LockModeType.PESSIMISTIC_WRITE));
      doAnswer(call -> {
        managedAttributes.forEach((id, attribute) -> {
          if (databaseValues.containsKey(id)) {
            databaseValues.put(id, attribute.getValue());
          }
        });
        persistedOtherName.set(otherEntity.getFirstName());
        return null;
      }).when(em).flush();
    }

    UserAttributeEntity attribute(String id, String name, String value) {
      var attribute = new UserAttributeEntity();
      attribute.setId(id);
      attribute.setUser(entity);
      attribute.setName(name);
      attribute.setValue(value);
      return attribute;
    }

    UserModel reload() {
      return ConsumerIdentityTransactions.refreshUser(session, realm, originalAdapter);
    }
  }
}
