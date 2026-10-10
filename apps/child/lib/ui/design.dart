import 'package:flutter/material.dart';

const childNavy = Color(0xFF19335C);
const childMuted = Color(0xFF67758A);
const childLine = Color(0xFFE2E8F0);
const childSoft = Color(0xFFF3F7FB);
const childTeal = Color(0xFF127E70);

ButtonStyle _filledButtonStyle(bool television) {
  final focusOutline = WidgetStateProperty.resolveWith<BorderSide?>((states) {
    return states.contains(WidgetState.focused)
        ? const BorderSide(color: childTeal, width: 3)
        : BorderSide.none;
  });
  return ButtonStyle(
    minimumSize: WidgetStatePropertyAll(Size(0, television ? 56 : 48)),
    padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 20, vertical: 16)),
    shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
    side: focusOutline,
  );
}

NavigationRailThemeData _televisionRailTheme() {
  const selectedLabel =
      TextStyle(color: childNavy, fontSize: 18, fontWeight: FontWeight.w700);
  const idleLabel = TextStyle(color: childMuted, fontSize: 18);
  return const NavigationRailThemeData(
    backgroundColor: childSoft,
    indicatorColor: Color(0xFFE3F1EE),
    selectedIconTheme: IconThemeData(color: childNavy, size: 28),
    unselectedIconTheme: IconThemeData(color: childMuted, size: 26),
    selectedLabelTextStyle: selectedLabel,
    unselectedLabelTextStyle: idleLabel,
  );
}

ThemeData childTheme({bool television = false}) => ThemeData(
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
    focusColor: television ? const Color(0xFFD7ECE7) : null,
    colorScheme: ColorScheme.fromSeed(
        seedColor: childNavy, primary: childNavy, surface: Colors.white),
    scaffoldBackgroundColor: Colors.white,
    textTheme: const TextTheme(
            headlineMedium: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: childNavy,
                height: 1.3),
            titleLarge: TextStyle(
                fontSize: 20, fontWeight: FontWeight.w700, color: childNavy),
            titleMedium: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w600, color: childNavy),
            bodyLarge: TextStyle(fontSize: 16, height: 1.6, color: childMuted),
            bodyMedium: TextStyle(fontSize: 14, height: 1.6, color: childMuted))
        .apply(fontSizeFactor: television ? 1.16 : 1),
    inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.all(16),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: childLine)),
        disabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: childLine)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: childNavy, width: 2))),
    filledButtonTheme: FilledButtonThemeData(style: _filledButtonStyle(television)),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48))),
    dividerTheme: const DividerThemeData(color: childLine, thickness: 1, space: 40),
    navigationBarTheme: const NavigationBarThemeData(backgroundColor: childSoft, indicatorColor: Color(0xFFE3F1EE), height: 72),
    navigationRailTheme: television ? _televisionRailTheme() : null);

class ChildNotice extends StatelessWidget {
  final String title;
  final String? detail;
  final bool warning;
  const ChildNotice(this.title, {super.key, this.detail, this.warning = false});
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: warning ? const Color(0xFFFFF6E8) : childSoft,
          borderRadius: BorderRadius.circular(10)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.info_outline,
            color: warning ? const Color(0xFF946000) : childNavy, size: 22),
        const SizedBox(width: 12),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: TextStyle(
                  color: warning ? const Color(0xFF805300) : childNavy,
                  fontWeight: FontWeight.w600,
                  height: 1.5)),
          if (detail != null)
            Text(detail!, style: Theme.of(context).textTheme.bodyMedium)
        ]))
      ]));
}
