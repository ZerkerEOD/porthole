/// Images in the chat: thumbnails carried by events, images the assistant
/// names by path (fetched from the machine), a full-screen viewer and Save.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../client.dart';
import '../models.dart';

/// Tallest a thumbnail is drawn in the chat.
const double thumbMaxHeight = 180;

/// Image file extensions recognised in paths.
final _imageExt = RegExp(r'\.(png|jpe?g|webp|gif)$', caseSensitive: false);

/// True for an absolute (`/…`) or home-relative (`~/…`) path to an image.
bool isImagePath(String p) => (p.startsWith('/') || p.startsWith('~/')) && _imageExt.hasMatch(p);

/// Bare absolute or home-relative image paths in assistant text, outside
/// fenced code and markdown image syntax, in order and without repeats.
List<String> bareImagePaths(String text, {int max = 6}) {
  final prose = text.replaceAll(RegExp(r'```[\s\S]*?(```|$)'), ' ').replaceAll(RegExp(r'!\[[^\[\]]*\]\([^\s)]*\)'), ' ');
  final re = RegExp(
    r'(?<![\w/.~(\]:-])((?:~/|/)[^\s`'
    "'"
    r'"()<>\[\]]+\.(?:png|jpe?g|webp|gif))(?![\w/])',
    caseSensitive: false,
  );
  final out = <String>[];
  for (final m in re.allMatches(prose)) {
    final p = m.group(1)!;
    if (!out.contains(p)) out.add(p);
    if (out.length >= max) break;
  }
  return out;
}

/// The images of one event as a row of thumbnails; an image the daemon left
/// out shows a placeholder with its size.
class EventImages extends StatelessWidget {
  const EventImages({super.key, required this.images});
  final List<EventImage> images;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      for (final img in images)
        if (img.bytesDecoded case final bytes? when !img.omitted)
          ImageThumb(bytes: bytes, mediaType: img.mediaType)
        else
          ImagePlaceholder(text: img.bytes > 0 ? 'image not shown (${compactBytes(img.bytes)})' : 'image not shown'),
    ],
  );
}

/// A grey box standing in for an image that is not shown.
class ImagePlaceholder extends StatelessWidget {
  const ImagePlaceholder({super.key, required this.text, this.icon = Icons.image_not_supported_outlined});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
          Flexible(
            child: Text(text, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}

/// A rounded thumbnail: tap opens the viewer, long press offers Save.
class ImageThumb extends StatelessWidget {
  const ImageThumb({super.key, required this.bytes, required this.mediaType, this.name});
  final Uint8List bytes;
  final String mediaType;

  /// A file name hint for Save.
  final String? name;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => openImageViewer(context, bytes, mediaType: mediaType, name: name),
    onLongPress: () => _imageMenu(context, bytes, mediaType, name),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: thumbMaxHeight, maxWidth: 280),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.memory(
          bytes,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (context, _, _) => const ImagePlaceholder(text: 'image could not be shown', icon: Icons.broken_image_outlined),
        ),
      ),
    ),
  );
}

Future<void> _imageMenu(BuildContext context, Uint8List bytes, String mediaType, String? name) async {
  final save = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: ListTile(leading: const Icon(Icons.download_outlined), title: const Text('Save'), onTap: () => Navigator.of(context).pop(true)),
    ),
  );
  if (save == true && context.mounted) await saveImage(context, bytes, mediaType, name: name);
}

/// Writes the image to the app's documents folder and says where.
Future<void> saveImage(BuildContext context, Uint8List bytes, String mediaType, {String? name}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final dir = await getApplicationDocumentsDirectory();
    final ext = switch (mediaType) {
      'image/jpeg' => 'jpg',
      'image/webp' => 'webp',
      'image/gif' => 'gif',
      _ => 'png',
    };
    final base = (name ?? '').split('/').last.replaceAll(RegExp(r'\.[A-Za-z0-9]+$'), '').replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[^0-9]'), '').substring(0, 14);
    final f = File('${dir.path}/${base.isEmpty ? 'image' : base}-$stamp.$ext');
    await f.writeAsBytes(bytes, flush: true);
    messenger?.showSnackBar(SnackBar(content: Text('Saved to ${f.path}')));
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text('Could not save the image: $e')));
  }
}

/// A full-screen view of one image with pinch zoom.
Future<void> openImageViewer(BuildContext context, Uint8List bytes, {String mediaType = '', String? name}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => ImageViewer(bytes: bytes, mediaType: mediaType, name: name),
  ),
);

class ImageViewer extends StatelessWidget {
  const ImageViewer({super.key, required this.bytes, this.mediaType = '', this.name});
  final Uint8List bytes;
  final String mediaType;
  final String? name;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      leading: IconButton(tooltip: 'Close', icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
      title: name == null ? null : Text(name!.split('/').last, style: const TextStyle(fontSize: 14)),
      actions: [
        IconButton(
          tooltip: 'Save',
          icon: const Icon(Icons.download_outlined),
          onPressed: () => saveImage(context, bytes, mediaType, name: name),
        ),
      ],
    ),
    body: InteractiveViewer(
      minScale: 1,
      maxScale: 8,
      child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
    ),
  );
}

/// An image the assistant named by path, fetched once from the session's
/// machine with `file.get` (cached on the client). Falls back to the path
/// as text when the machine will not serve it.
class RemoteImage extends StatefulWidget {
  const RemoteImage({super.key, required this.client, required this.sessionKey, required this.path});
  final DaemonClient client;
  final String sessionKey;
  final String path;

  @override
  State<RemoteImage> createState() => _RemoteImageState();
}

class _RemoteImageState extends State<RemoteImage> {
  late Future<({Uint8List bytes, String mediaType})> _f;

  @override
  void initState() {
    super.initState();
    _f = widget.client.getFile(widget.sessionKey, widget.path);
  }

  @override
  void didUpdateWidget(RemoteImage old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path || old.sessionKey != widget.sessionKey || old.client != widget.client) {
      _f = widget.client.getFile(widget.sessionKey, widget.path);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<({Uint8List bytes, String mediaType})>(
    future: _f,
    builder: (context, snap) {
      final cs = Theme.of(context).colorScheme;
      if (snap.hasError) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(widget.path, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            Text('not available', style: TextStyle(fontSize: 10, color: cs.outline)),
          ],
        );
      }
      final d = snap.data;
      if (d == null) {
        return Container(
          key: const ValueKey('remote-image-loading'),
          width: 160,
          height: 100,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(10)),
          child: Icon(Icons.image_outlined, color: cs.onSurfaceVariant),
        );
      }
      return ImageThumb(bytes: d.bytes, mediaType: d.mediaType, name: widget.path);
    },
  );
}
