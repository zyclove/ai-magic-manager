import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'design.dart';

typedef TvContentBuilder = Widget Function(ScrollController controller);

final _remoteButtonStyle = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(0, 56)),
    side: WidgetStateProperty.resolveWith((states) =>
        states.contains(WidgetState.focused)
            ? const BorderSide(color: childTeal, width: 3)
            : const BorderSide(color: childMuted)));

/// Remote navigation for an already connected television. This owns only
/// focus/scroll state; identity, permissions and device operations stay in the
/// existing child session and page widgets.
class TvWorkspace extends StatefulWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final TvContentBuilder contentBuilder;
  const TvWorkspace(
      {super.key,
      required this.selectedIndex,
      required this.onDestinationSelected,
      required this.contentBuilder});

  @override
  State<TvWorkspace> createState() => _TvWorkspaceState();
}

class _TvWorkspaceState extends State<TvWorkspace> {
  final _menu = FocusScopeNode(debugLabel: 'TV menu');
  final _content = FocusScopeNode(debugLabel: 'TV content');
  final _scroll = ScrollController();
  bool _inContent = false;
  bool _metricsQueued = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_metricsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ModalRoute.of(context)?.isCurrent != false) _toMenu();
    });
  }

  @override
  void didUpdateWidget(TvWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_scroll.hasClients) _scroll.jumpTo(0);
        // Selecting a destination keeps the menu focus stable. Right enters
        // its actions; page-originated navigation keeps the content context.
        if (_inContent) _toContent();
      });
    }
  }

  @override
  void dispose() {
    _menu.dispose();
    _content.dispose();
    _scroll.removeListener(_metricsChanged);
    _scroll.dispose();
    super.dispose();
  }

  void _metricsChanged() {
    if (_metricsQueued) return;
    _metricsQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _metricsQueued = false;
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _toMenu() {
    if (_menu.focusedChild != null) {
      _menu.requestFocus();
    } else {
      _menu.nextFocus();
    }
  }

  void _toContent() {
    if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
    if (_content.focusedChild != null) {
      _content.requestFocus();
    } else {
      _content.nextFocus();
    }
  }

  bool get _editing {
    final context = FocusManager.instance.primaryFocus?.context;
    return context?.widget is EditableText ||
        context?.findAncestorStateOfType<EditableTextState>() != null;
  }

  void _page(int direction) {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final target =
        (position.pixels + direction * position.viewportDimension * .8)
            .clamp(position.minScrollExtent, position.maxScrollExtent)
            .toDouble();
    if ((target - position.pixels).abs() < 1) return;
    if (MediaQuery.of(context).disableAnimations) {
      _scroll.jumpTo(target);
    } else {
      unawaited(_scroll
          .animateTo(target,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut)
          .catchError((Object _) {}));
    }
  }

  KeyEventResult _menuKey(FocusNode _, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _toContent();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _contentKey(FocusNode _, KeyEvent event) {
    if ((event is! KeyDownEvent && event is! KeyRepeatEvent) || _editing) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape ||
        event.logicalKey == LogicalKeyboardKey.goBack) {
      _toMenu();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.pageDown ||
        event.logicalKey == LogicalKeyboardKey.pageUp) {
      _page(event.logicalKey == LogicalKeyboardKey.pageDown ? 1 : -1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String get _readingPosition {
    if (!_scroll.hasClients || _scroll.position.maxScrollExtent <= 1) {
      return '全部内容已显示';
    }
    if (_scroll.position.extentBefore <= 1) return '已到顶部';
    if (_scroll.position.extentAfter <= 1) return '已到底部';
    return '可继续阅读';
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !_inContent,
      onPopInvoked: (didPop) {
        if (!didPop && _inContent) _toMenu();
      },
      child: Row(children: [
        SafeArea(
            child: Focus(
                canRequestFocus: false,
                onKeyEvent: _menuKey,
                child: FocusScope(
                    node: _menu,
                    child: NavigationRail(
                      extended: true,
                      minExtendedWidth: 220,
                      backgroundColor: childSoft,
                      selectedLabelTextStyle: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(
                              color: childNavy,
                              fontSize: 18,
                              fontWeight: FontWeight.w700),
                      unselectedLabelTextStyle: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(
                              color: childMuted,
                              fontSize: 18,
                              fontWeight: FontWeight.w400),
                      selectedIndex: widget.selectedIndex,
                      onDestinationSelected: (index) {
                        if (index == widget.selectedIndex) {
                          _toContent();
                        } else {
                          widget.onDestinationSelected(index);
                        }
                      },
                      leading: const Padding(
                          padding: EdgeInsets.fromLTRB(20, 24, 20, 32),
                          child: Text('智能管家',
                              style: TextStyle(
                                  color: childNavy,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700))),
                      destinations: const [
                        NavigationRailDestination(
                            icon: Icon(Icons.phone_android), label: Text('设备')),
                        NavigationRailDestination(
                            icon: Icon(Icons.description_outlined),
                            label: Text('规则')),
                        NavigationRailDestination(
                            icon: Icon(Icons.bar_chart_outlined),
                            label: Text('使用')),
                        NavigationRailDestination(
                            icon: Icon(Icons.help_outline), label: Text('帮助')),
                      ],
                    )))),
        const VerticalDivider(width: 1),
        Expanded(
            child: Focus(
                canRequestFocus: false,
                onKeyEvent: _contentKey,
                child: FocusScope(
                    node: _content,
                    onFocusChange: (value) {
                      if (mounted) setState(() => _inContent = value);
                    },
                    child: FocusTraversalGroup(
                        policy: OrderedTraversalPolicy(),
                        child: Column(children: [
                          Expanded(
                              child: FocusTraversalOrder(
                                  order: const NumericFocusOrder(0),
                                  child: NotificationListener<
                                          ScrollMetricsNotification>(
                                      onNotification: (_) {
                                        _metricsChanged();
                                        return false;
                                      },
                                      child: widget.contentBuilder(_scroll)))),
                          FocusTraversalOrder(
                              order: const NumericFocusOrder(1),
                              child: Material(
                                  color: childSoft,
                                  child: SafeArea(
                                      top: false,
                                      child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 16, vertical: 8),
                                          child: Wrap(
                                              spacing: 12,
                                              runSpacing: 4,
                                              crossAxisAlignment:
                                                  WrapCrossAlignment.center,
                                              children: [
                                                TextButton.icon(
                                                    style: _remoteButtonStyle,
                                                    onPressed: _toMenu,
                                                    icon: const Icon(
                                                        Icons.arrow_back),
                                                    label: const Text('返回菜单')),
                                                OutlinedButton.icon(
                                                    style: _remoteButtonStyle,
                                                    onPressed: () => _page(-1),
                                                    icon: const Icon(Icons
                                                        .keyboard_arrow_up),
                                                    label: const Text('向上翻页')),
                                                OutlinedButton.icon(
                                                    style: _remoteButtonStyle,
                                                    onPressed: () => _page(1),
                                                    icon: const Icon(Icons
                                                        .keyboard_arrow_down),
                                                    label: const Text('向下翻页')),
                                                Text(_readingPosition),
                                              ]))))),
                        ]))))),
      ]));
}
