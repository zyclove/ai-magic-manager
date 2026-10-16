package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.assertThat;

import com.google.api.client.http.javanet.NetHttpTransport;
import com.google.api.client.json.gson.GsonFactory;
import com.google.api.services.androidmanagement.v1.AndroidManagement;
import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.Test;

/** Official SDK against loopback only. No real enterprise, credentials or device. */
class GoogleManagedDeviceProfileReaderTest {
  @Test
  void readsProviderDeviceFactsWithoutWriting() throws Exception {
    var reads = new AtomicInteger();
    var writes = new AtomicInteger();
    var server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
    server.createContext(
        "/",
        exchange -> {
          if (exchange.getRequestMethod().equals("GET")) reads.incrementAndGet();
          else writes.incrementAndGet();
          byte[] body =
              """
              {"name":"enterprises/e1/devices/d1","managementMode":"DEVICE_OWNER",
               "apiLevel":30,"state":"ACTIVE","appliedState":"ACTIVE",
               "lastStatusReportTime":"2026-10-16T10:00:00Z"}
              """
                  .getBytes(StandardCharsets.UTF_8);
          exchange.getResponseHeaders().set("Content-Type", "application/json");
          exchange.sendResponseHeaders(200, body.length);
          exchange.getResponseBody().write(body);
          exchange.close();
        });
    server.start();
    try {
      var client =
          new AndroidManagement.Builder(
                  new NetHttpTransport(), GsonFactory.getDefaultInstance(), request -> {})
              .setRootUrl("http://127.0.0.1:" + server.getAddress().getPort() + "/")
              .setApplicationName("device-profile-local-contract")
              .build();
      var result = GoogleManagedDeviceProfileReader.read(client, "enterprises/e1/devices/d1");
      assertThat(result).as("provider execution profile must be read").isNotNull();
      assertThat(result.deviceName()).isEqualTo("enterprises/e1/devices/d1");
      assertThat(result.managementMode()).isEqualTo("DEVICE_OWNER");
      assertThat(result.apiLevel()).isEqualTo(30);
      assertThat(result.state()).isEqualTo("ACTIVE");
      assertThat(result.appliedState()).isEqualTo("ACTIVE");
      assertThat(result.lastStatusReportTime()).isEqualTo("2026-10-16T10:00:00Z");
      assertThat(reads.get()).isEqualTo(1);
      assertThat(writes.get()).isZero();
    } finally {
      server.stop(0);
    }
  }
}
