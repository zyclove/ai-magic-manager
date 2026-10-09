// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:js_util' as js;

/// Uses the browser's maintained IANA data, independent of the browser's local zone.
/// An unsupported identifier leaves the required date empty for explicit selection.
String localDateInZone(DateTime instant, String timeZone) {
  try {
    final intl = js.getProperty<Object>(html.window, 'Intl');
    final constructor = js.getProperty<Object>(intl, 'DateTimeFormat');
    final formatter = js.callConstructor<Object>(constructor, [
      'en-US',
      js.jsify({
        'timeZone': timeZone,
        'calendar': 'gregory',
        'numberingSystem': 'latn',
        'year': 'numeric',
        'month': '2-digit',
        'day': '2-digit',
      })
    ]);
    final parts = js.dartify(js.callMethod<Object>(
        formatter, 'formatToParts', [instant.millisecondsSinceEpoch])) as List;
    final values = <String, String>{
      for (final part in parts) part['type'] as String: part['value'] as String
    };
    return '${values['year']}-${values['month']}-${values['day']}';
  } catch (_) {
    return '';
  }
}
