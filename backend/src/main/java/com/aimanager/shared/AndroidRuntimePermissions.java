package com.aimanager.shared;

import java.util.Set;

/** Android permissions accepted by the product's per-application runtime policy surface. */
public final class AndroidRuntimePermissions {
  private static final String PREFIX = "android.permission.";
  private static final Set<String> NAMES = Set.of(
      "CAMERA", "RECORD_AUDIO", "READ_CONTACTS", "WRITE_CONTACTS", "GET_ACCOUNTS",
      "READ_CALENDAR", "WRITE_CALENDAR", "ACCESS_COARSE_LOCATION", "ACCESS_FINE_LOCATION",
      "ACCESS_BACKGROUND_LOCATION", "POST_NOTIFICATIONS", "READ_MEDIA_IMAGES",
      "READ_MEDIA_VIDEO", "READ_MEDIA_AUDIO", "READ_MEDIA_VISUAL_USER_SELECTED",
      "READ_EXTERNAL_STORAGE", "WRITE_EXTERNAL_STORAGE", "BLUETOOTH_SCAN", "BLUETOOTH_CONNECT",
      "BLUETOOTH_ADVERTISE", "NEARBY_WIFI_DEVICES", "BODY_SENSORS",
      "BODY_SENSORS_BACKGROUND", "READ_PHONE_STATE", "READ_PHONE_NUMBERS", "CALL_PHONE",
      "ANSWER_PHONE_CALLS", "ADD_VOICEMAIL", "USE_SIP", "PROCESS_OUTGOING_CALLS",
      "ACTIVITY_RECOGNITION", "READ_SMS", "SEND_SMS", "RECEIVE_SMS", "RECEIVE_MMS",
      "RECEIVE_WAP_PUSH", "READ_CALL_LOG", "WRITE_CALL_LOG", "UWB_RANGING");

  private AndroidRuntimePermissions() {}

  public static boolean contains(String permission) {
    return permission != null && permission.startsWith(PREFIX)
        && NAMES.contains(permission.substring(PREFIX.length()));
  }
}
