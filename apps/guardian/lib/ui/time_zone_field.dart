import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:timezone/data/latest.dart' as time_zone_data;
import 'package:timezone/timezone.dart' as time_zones;

/// Suggests local IANA names without restricting values accepted by the server.
/// The caller owns [controller] and the synchronous interaction permission.
class TimeZoneField extends StatefulWidget {
  final TextEditingController controller;
  final bool enabled, autofocus;
  final String label;
  final String? hint;
  final int? maxLength;
  final FormFieldValidator<String>? validator;
  final bool Function()? canInteract;

  const TimeZoneField(
      {super.key,
      required this.controller,
      required this.enabled,
      this.label = '时区',
      this.hint,
      this.autofocus = false,
      this.maxLength,
      this.validator,
      this.canInteract});

  @override
  State<TimeZoneField> createState() => _TimeZoneFieldState();
}

class _TimeZoneFieldState extends State<TimeZoneField> {
  late final focus = FocusNode(canRequestFocus: widget.enabled);
  final optionsScroll = ScrollController(debugLabel: 'time-zone-options');
  int generation = 0;
  int highlightedOption = -1;
  bool active = true;

  bool permitted(int epoch, TextEditingController controller) =>
      mounted &&
      active &&
      generation == epoch &&
      identical(widget.controller, controller) &&
      widget.enabled &&
      widget.canInteract?.call() != false;

  @override
  void didUpdateWidget(TimeZoneField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled ||
        !identical(oldWidget.controller, widget.controller)) {
      generation++;
      focus.unfocus();
    }
    focus.canRequestFocus = widget.enabled;
  }

  @override
  void deactivate() {
    active = false;
    generation++;
    focus.unfocus();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    active = true;
  }

  @override
  void dispose() {
    active = false;
    generation++;
    focus.dispose();
    optionsScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final epoch = generation;
    final controller = widget.controller;
    bool current() => permitted(epoch, controller);
    return LayoutBuilder(builder: (context, constraints) {
      final width = math.min(
          constraints.hasBoundedWidth ? constraints.maxWidth : 360.0, 520.0);
      return RawAutocomplete<String>(
          textEditingController: controller,
          focusNode: focus,
          displayStringForOption: (zone) => zone,
          optionsBuilder: (value) =>
              current() ? _suggestions(value.text) : const <String>[],
          fieldViewBuilder: (context, fieldController, fieldFocus, submit) =>
              TextFormField(
                  controller: fieldController,
                  focusNode: fieldFocus,
                  enabled: widget.enabled,
                  autofocus: widget.autofocus,
                  maxLength: widget.maxLength,
                  validator: widget.validator,
                  decoration: InputDecoration(
                      labelText: widget.label,
                      hintText: widget.hint ?? '搜索城市后选择，或输入时区编号'),
                  onFieldSubmitted: (_) {
                    // RawAutocomplete changes the controller before onSelected.
                    if (current()) submit();
                  }),
          optionsViewBuilder: (context, select, values) {
            if (!current()) return const SizedBox.shrink();
            final options = values.toList(growable: false);
            highlightedOption = AutocompleteHighlightedOption.of(context);
            return Align(
                alignment: Alignment.topLeft,
                child: Material(
                    elevation: 6,
                    borderRadius: BorderRadius.circular(8),
                    clipBehavior: Clip.antiAlias,
                    child: SizedBox(
                        width: width,
                        child: ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 280),
                            child: SingleChildScrollView(
                                key: const ValueKey('time-zone-options-scroll'),
                                controller: optionsScroll,
                                primary: false,
                                padding: const EdgeInsets.symmetric(vertical: 4),
                                child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      for (var index = 0; index < options.length; index++)
                                        Builder(builder: (optionContext) {
                                          final zone = options[index];
                                          final city = _cities[zone];
                                          final highlighted = highlightedOption == index;
                                          if (highlighted) {
                                            WidgetsBinding.instance.addPostFrameCallback((_) {
                                              if (!current() || !optionContext.mounted ||
                                                  !focus.hasFocus || !optionsScroll.hasClients ||
                                                  highlightedOption != index) return;
                                              final target = optionContext.findRenderObject();
                                              if (target != null && target.attached) {
                                                // Only this popup scrolls; do not traverse
                                                // the caller's ancestor scrollables.
                                                optionsScroll.position.ensureVisible(target,
                                                    alignment: .5);
                                              }
                                            });
                                          }
                                          return ListTile(
                                              key: ValueKey('time-zone-option-$zone'),
                                              selected: highlighted,
                                              title: Text(city ?? zone,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis),
                                              subtitle: city == null ? null : Text(zone),
                                              onTap: () {
                                                if (current()) select(zone);
                                              });
                                        }),
                                    ]))))));
          });
    });
  }
}

const _cities = <String, String>{
  'Asia/Shanghai': '北京 / 上海 / 广州 / 深圳',
  'UTC': '协调世界时',
  'Asia/Hong_Kong': '香港',
  'Asia/Taipei': '台北 / 台湾',
  'Asia/Tokyo': '东京 / 日本',
  'Asia/Seoul': '首尔 / 韩国',
  'Asia/Singapore': '新加坡',
  'Asia/Bangkok': '曼谷 / 泰国',
  'Asia/Kolkata': '新德里 / 印度',
  'Europe/London': '伦敦 / 英国',
  'Europe/Paris': '巴黎 / 法国',
  'America/New_York': '纽约 / 美国东部',
  'America/Los_Angeles': '洛杉矶 / 美国西部',
  'Australia/Sydney': '悉尼 / 澳大利亚',
  'Pacific/Auckland': '奥克兰 / 新西兰',
};

List<String>? _catalog;

Iterable<String> _suggestions(String text) {
  if (_catalog == null) {
    final database = time_zones.timeZoneDatabase;
    if (!database.isInitialized) {
      time_zones.Location? previousLocal;
      try {
        previousLocal = time_zones.local;
      } on Error {
        // The package's late local getter is unset before its first initialization.
      }
      time_zone_data.initializeTimeZones();
      if (previousLocal != null) time_zones.setLocalLocation(previousLocal);
    }
    final names = database.locations.keys.toList()..sort();
    _catalog = List<String>.unmodifiable([
      for (final name in _cities.keys)
        if (name == 'UTC' || database.locations.containsKey(name)) name,
      for (final name in names)
        if (!_cities.containsKey(name)) name,
    ]);
  }
  final query = text.trim().toLowerCase();
  return _catalog!.where((zone) {
    final searchable = '$zone ${zone.replaceAll('_', ' ')} ${_cities[zone] ?? ''}'
        .toLowerCase();
    return query.isEmpty || searchable.contains(query);
  }).take(12).toList(growable: false);
}
