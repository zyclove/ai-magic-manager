// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';

/// Hand a validated JSON document to the browser without retaining a URL.
/// Completion means handed to the browser; the user may still cancel saving.
Future<void> saveBrowserJson(
    Uint8List bytes, String filename, void Function() ensureCurrent) async {
  ensureCurrent();
  final url =
      html.Url.createObjectUrlFromBlob(html.Blob([bytes], 'application/json'));
  final anchor = html.AnchorElement(href: url)
    ..download = filename
    ..style.display = 'none';
  try {
    html.document.body!.append(anchor);
    ensureCurrent();
    anchor.click();
  } finally {
    anchor.remove();
    Future<void>.delayed(
        const Duration(seconds: 30), () => html.Url.revokeObjectUrl(url));
  }
}
