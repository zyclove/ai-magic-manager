import 'package:flutter/material.dart';
import 'design.dart';

/// Login presentation only; the session owns the authorization redirect.
class LoginView extends StatelessWidget {
  final VoidCallback onLogin;
  final Object? error;
  const LoginView({super.key, required this.onLogin, this.error});

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width > 900;
    return Scaffold(
        body: SafeArea(
            child: Row(children: [
      if (wide) const Expanded(child: _LoginBrandPanel()),
      Expanded(
          child: Center(
              child: SingleChildScrollView(
                  padding: const EdgeInsets.all(28),
                  child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (!wide)
                              const Padding(
                                  padding: EdgeInsets.only(bottom: 36),
                                  child: Icon(Icons.shield_outlined,
                                      size: 44, color: navy)),
                            const Text('欢迎回来',
                                style: TextStyle(
                                    fontSize: 32,
                                    fontWeight: FontWeight.w700,
                                    color: ink)),
                            const SizedBox(height: 12),
                            const Text('登录智能管家，继续管理你的工作空间。',
                                style: TextStyle(color: muted, fontSize: 15)),
                            const SizedBox(height: 36),
                            if (error != null)
                              Padding(
                                  padding: const EdgeInsets.only(bottom: 20),
                                  child: FailureView(error!)),
                            SizedBox(
                                width: double.infinity,
                                child: FilledButton.icon(
                                    onPressed: onLogin,
                                    icon: const Icon(Icons.login, size: 20),
                                    label: const Text('安全登录'))),
                            const SizedBox(height: 20),
                            const Text(
                                '在身份服务中输入管理员邮箱和密码。你的密码不会存储在此应用中。',
                                style: TextStyle(
                                    color: muted, fontSize: 13, height: 1.8)),
                            const SizedBox(height: 48),
                            const Divider(),
                            const SizedBox(height: 20),
                            const Row(children: [
                              Icon(Icons.verified_user_outlined,
                                  color: muted, size: 18),
                              SizedBox(width: 10),
                              Expanded(
                                  child: Text('统一身份认证 · 按工作空间授权',
                                      style: TextStyle(
                                          color: muted, fontSize: 12)))
                            ]),
                          ]))))),
    ])));
  }
}

class _LoginBrandPanel extends StatelessWidget {
  const _LoginBrandPanel();

  @override
  Widget build(BuildContext context) => ColoredBox(
      color: navy,
      child: LayoutBuilder(
          builder: (context, bounds) => SingleChildScrollView(
              // The login pane keeps its own primary scroll/focus behavior.
              primary: false,
              child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: bounds.maxHeight),
                  child: const Padding(
                      padding: EdgeInsets.all(64),
                      child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Icon(Icons.shield_outlined,
                                  color: Colors.white, size: 32),
                              SizedBox(width: 12),
                              Text('智能管家',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 23,
                                      fontWeight: FontWeight.w700))
                            ]),
                            Padding(
                                padding: EdgeInsets.symmetric(vertical: 48),
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text('让每一次数字探索，\n都有安心的陪伴。',
                                          style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 40,
                                              fontWeight: FontWeight.w600,
                                              height: 1.6)),
                                      SizedBox(height: 24),
                                      Text('连接家庭设备，安排使用时间，\n让规则清晰，让成长更从容。',
                                          style: TextStyle(
                                              color: Color(0xFFB7C9E0),
                                              fontSize: 17,
                                              height: 1.9)),
                                    ])),
                            Text('AI MANAGER  /  家庭与教育设备管理',
                                style: TextStyle(
                                    color: Color(0xFFB7C9E0), fontSize: 12)),
                          ]))))));
}
