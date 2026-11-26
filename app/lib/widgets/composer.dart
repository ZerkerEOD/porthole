import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models.dart';

/// An image picked in the composer, waiting to go out with the message.
class PendingImage {
  const PendingImage({required this.bytes, required this.name, required this.mediaType});
  final Uint8List bytes;
  final String name;
  final String mediaType;
}

/// Largest image the machine accepts, decoded.
const maxImageBytes = 10 * 1024 * 1024;

/// The image type from the file's first bytes: image/png, image/jpeg,
/// image/gif or image/webp, or null for anything else.
String? sniffImageType(Uint8List b) {
  bool at(int i, List<int> sig) => b.length >= i + sig.length && [for (var k = 0; k < sig.length; k++) b[i + k] == sig[k]].every((x) => x);
  if (at(0, [0x89, 0x50, 0x4E, 0x47])) return 'image/png';
  if (at(0, [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (at(0, [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (at(0, [0x52, 0x49, 0x46, 0x46]) && at(8, [0x57, 0x45, 0x42, 0x50])) return 'image/webp';
  return null;
}

/// The message text sent for an attached image saved at [path].
String withAttachedImage(String text, String path) => text.trim().isEmpty ? 'Attached image: $path' : '${text.trim()}\n\nAttached image: $path';

/// Multi-line input with slash-command autocomplete. The text is editable
/// while the machine is unreachable; only Send waits for the connection.
class Composer extends StatefulWidget {
  const Composer({super.key, required this.onSend, required this.skills, this.enabled = true, this.online = true, this.hint = 'Message', this.initialText = '', this.onChanged, this.onUpload});
  final Future<void> Function(String text) onSend;

  /// Uploads an attached image to the machine and returns its path there;
  /// null hides the attach button.
  final Future<String> Function(PendingImage image)? onUpload;
  final List<Skill> skills;
  final bool enabled;
  /// False while the connection is down: Send is disabled and the field
  /// says so.
  final bool online;
  final String hint;
  /// The draft restored into the field when the composer is built.
  final String initialText;
  /// Every edit, and an empty string once a send went through.
  final void Function(String text)? onChanged;
  @override
  State<Composer> createState() => ComposerState();
}

class ComposerState extends State<Composer> {
  late final _ctl = TextEditingController(text: widget.initialText);
  final _focus = FocusNode();
  bool _sending = false;
  PendingImage? _image;

  /// The attached image, if any.
  PendingImage? get pendingImage => _image;

  /// Attaches [image] as if it had been picked; for tests, which cannot
  /// drive the platform picker.
  @visibleForTesting
  void attachForTest(PendingImage image) => setState(() => _image = image);

  Future<void> _pick() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.photo_camera_outlined), title: const Text('Camera'), onTap: () => Navigator.of(context).pop(ImageSource.camera)),
          ListTile(leading: const Icon(Icons.photo_library_outlined), title: const Text('Photo library'), onTap: () => Navigator.of(context).pop(ImageSource.gallery)),
        ]),
      ),
    );
    if (source == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      // The picker scales photos to 2048 px on the long side and re-encodes
      // JPEG at quality 85; a PNG stays a PNG.
      final f = await ImagePicker().pickImage(source: source, maxWidth: 2048, maxHeight: 2048, imageQuality: 85, requestFullMetadata: false);
      if (f == null) return;
      final bytes = await f.readAsBytes();
      final type = sniffImageType(bytes);
      if (type == null) {
        messenger.showSnackBar(const SnackBar(content: Text('Only PNG, JPEG, WebP and GIF images can be attached.')));
        return;
      }
      if (bytes.length > maxImageBytes) {
        messenger.showSnackBar(SnackBar(content: Text('The image is too large to send (${compactBytes(bytes.length)}; the limit is 10 MB).')));
        return;
      }
      final ext = switch (type) {
        'image/jpeg' => 'jpg',
        'image/webp' => 'webp',
        'image/gif' => 'gif',
        _ => 'png',
      };
      final stem = f.name.replaceAll(RegExp(r'\.[A-Za-z0-9]+$'), '');
      if (mounted) setState(() => _image = PendingImage(bytes: bytes, name: '${stem.isEmpty ? 'image' : stem}.$ext', mediaType: type));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not attach the image: $e')));
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  List<Skill> get _matches {
    final t = _ctl.text;
    if (!t.startsWith('/') || t.contains('\n')) return const [];
    final q = t.substring(1).toLowerCase();
    final head = q.split(' ').first;
    if (q.contains(' ')) return const [];
    return widget.skills.where((s) => s.name.toLowerCase().contains(head)).take(8).toList();
  }

  Future<void> _send() async {
    var text = _ctl.text.trim();
    final image = _image;
    if ((text.isEmpty && image == null) || _sending) return;
    setState(() => _sending = true);
    try {
      final upload = widget.onUpload;
      if (image != null && upload != null) text = withAttachedImage(text, await upload(image));
      await widget.onSend(text);
      _ctl.clear();
      if (mounted && identical(_image, image)) setState(() => _image = null);
      widget.onChanged?.call('');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final matches = _matches;
    return Material(
      color: cs.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (matches.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final s in matches)
                    ListTile(
                      dense: true,
                      leading: Icon(s.source == 'builtin' ? Icons.bolt : Icons.auto_awesome, size: 18),
                      title: Text('/${s.name}', style: const TextStyle(fontFamily: 'monospace')),
                      subtitle: s.description.isNotEmpty ? Text(s.description, maxLines: 2, overflow: TextOverflow.ellipsis) : null,
                      trailing: Text(s.source, style: Theme.of(context).textTheme.labelSmall),
                      onTap: () {
                        _ctl.text = '/${s.name} ';
                        _ctl.selection = TextSelection.collapsed(offset: _ctl.text.length);
                        widget.onChanged?.call(_ctl.text);
                        setState(() {});
                        _focus.requestFocus();
                      },
                    ),
                ],
              ),
            ),
          if (_image != null) _imageChip(context, _image!),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              if (widget.onUpload != null)
                IconButton(
                  key: const ValueKey('attach-image'),
                  tooltip: 'Attach an image',
                  onPressed: widget.enabled && !_sending ? _pick : null,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                ),
              Expanded(
                child: TextField(
                  controller: _ctl,
                  focusNode: _focus,
                  enabled: widget.enabled,
                  minLines: 1,
                  maxLines: 6,
                  textInputAction: TextInputAction.newline,
                  onChanged: (t) {
                    widget.onChanged?.call(t);
                    setState(() {});
                  },
                  decoration: InputDecoration(
                    hintText: widget.enabled ? widget.hint : 'Read-only: not running in tmux',
                    helperText: widget.enabled && !widget.online ? 'Sends when reconnected' : null,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
                    filled: true,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  ),
                ),
              ),
              IconButton.filled(onPressed: widget.enabled && widget.online && !_sending ? _send : null, icon: _sending ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send)),
            ]),
          ),
        ]),
      ),
    );
  }

  /// The attached image above the field, with a remove button.
  Widget _imageChip(BuildContext context, PendingImage img) {
    final cs = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        key: const ValueKey('pending-image'),
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        padding: const EdgeInsets.fromLTRB(4, 4, 0, 4),
        decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(10)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          ClipRRect(borderRadius: BorderRadius.circular(6), child: Image.memory(img.bytes, height: 48, width: 48, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox(width: 48, height: 48, child: Icon(Icons.image_outlined)))),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text('${img.name} · ${compactBytes(img.bytes.length)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
          ),
          IconButton(
            key: const ValueKey('remove-image'),
            tooltip: 'Remove the image',
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            onPressed: _sending ? null : () => setState(() => _image = null),
            icon: const Icon(Icons.close),
          ),
        ]),
      ),
    );
  }
}
