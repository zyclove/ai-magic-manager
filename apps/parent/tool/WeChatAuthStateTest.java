import com.aimanager.parent.ConsumerAuthState;
public final class WeChatAuthStateTest {
  public static void main(String[] args){
    ConsumerAuthState pending=new ConsumerAuthState();
    String state=pending.begin(1000);
    if(state==null||!state.matches("[a-f0-9]{64}"))throw new AssertionError("cryptographic state is missing");
    if(pending.accept("attacker-state",1100))throw new AssertionError("incorrect state accepted");
    if(!pending.accept(state,1200))throw new AssertionError("incorrect callback consumed live state");
    if(pending.accept(state,1300))throw new AssertionError("callback replay accepted");
    String expired=pending.begin(2000);
    if(pending.accept(expired,122000))throw new AssertionError("expired callback accepted");
    String cancelled=pending.begin(200000);pending.cancel();
    if(pending.accept(cancelled,200100))throw new AssertionError("cancelled callback accepted");
    System.out.println("WeChat native state: 5 checks passed");
  }
}
