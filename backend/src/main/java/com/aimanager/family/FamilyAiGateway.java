package com.aimanager.family;
import java.util.Map;
public interface FamilyAiGateway {
  boolean available();
  String model();
  Map<String,Object> suggest(Map<String,Object> input);
}
