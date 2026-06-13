import 'package:flutter/material.dart';

/// Shows a document's extracted text, scrolled to and highlighting the cited
/// passage — the non-PDF equivalent of opening a PDF at its page. Used for
/// Word/PowerPoint/Excel/EPUB/text citations, which have no native paginated
/// viewer but whose extracted text we keep in the corpus.
///
/// To stay instant even on a large book, it renders a generous window of text
/// around the quote rather than the whole document.
class DocTextViewerScreen extends StatefulWidget {
  const DocTextViewerScreen({
    super.key,
    required this.title,
    required this.fullText,
    required this.snippet,
  });

  final String title;
  final String fullText;
  final String snippet;

  @override
  State<DocTextViewerScreen> createState() => _DocTextViewerScreenState();
}

class _DocTextViewerScreenState extends State<DocTextViewerScreen> {
  static const int _window = 8000; // chars of context on each side of the quote

  final GlobalKey _highlightKey = GlobalKey();
  late final _Located _loc;

  @override
  void initState() {
    super.initState();
    _loc = _locate(widget.fullText, widget.snippet);
    if (_loc.found) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _highlightKey.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(ctx,
              alignment: 0.12, duration: const Duration(milliseconds: 350));
        }
      });
    }
  }

  /// Finds the quote in [text] with a whitespace-tolerant match on its leading
  /// and trailing words (the chunker may have re-joined lines), and returns the
  /// character window to render plus the highlight range within it.
  _Located _locate(String text, String snippet) {
    if (text.isEmpty) return const _Located.empty();
    final words = snippet
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    int start = -1, end = -1;
    if (words.length >= 2) {
      final head = RegExp(
          words.take(12).map(RegExp.escape).join(r'\s+'),
          caseSensitive: false, dotAll: true);
      final hm = head.firstMatch(text);
      if (hm != null) {
        start = hm.start;
        // Locate the tail after the head to bound the highlight precisely.
        final tailWords = words.length > 12 ? words.sublist(words.length - 8) : words;
        final tail = RegExp(tailWords.map(RegExp.escape).join(r'\s+'),
            caseSensitive: false, dotAll: true);
        final tm = tail.firstMatch(text.substring(start));
        end = tm != null
            ? start + tm.end
            : (start + snippet.length).clamp(start, text.length);
      }
    }
    if (start < 0) {
      // No reliable match — show the start of the document, no highlight.
      final winEnd = text.length < _window * 2 ? text.length : _window * 2;
      return _Located(
        found: false,
        before: text.substring(0, winEnd),
        highlight: '',
        after: '',
        leadingEllipsis: false,
        trailingEllipsis: winEnd < text.length,
      );
    }
    final winStart = (start - _window) < 0 ? 0 : start - _window;
    final winEnd = (end + _window) > text.length ? text.length : end + _window;
    return _Located(
      found: true,
      before: text.substring(winStart, start),
      highlight: text.substring(start, end),
      after: text.substring(end, winEnd),
      leadingEllipsis: winStart > 0,
      trailingEllipsis: winEnd < text.length,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = Theme.of(context).textTheme.bodyMedium;
    if (widget.fullText.trim().isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              "The extracted text for this document isn't available anymore. "
              'Re-scan to refresh it.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: Column(
        children: [
          if (!_loc.found)
            Material(
              color: scheme.secondaryContainer,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(
                  "Couldn't pinpoint the exact quote — showing the document.",
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: SelectableText.rich(
                TextSpan(
                  style: base,
                  children: [
                    if (_loc.leadingEllipsis)
                      const TextSpan(text: '…\n\n'),
                    TextSpan(text: _loc.before),
                    if (_loc.highlight.isNotEmpty)
                      WidgetSpan(
                        alignment: PlaceholderAlignment.baseline,
                        baseline: TextBaseline.alphabetic,
                        child: Container(
                          key: _highlightKey,
                          decoration: BoxDecoration(
                            color: scheme.tertiaryContainer,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(_loc.highlight,
                              style: base?.copyWith(
                                  color: scheme.onTertiaryContainer,
                                  fontWeight: FontWeight.w500)),
                        ),
                      ),
                    TextSpan(text: _loc.after),
                    if (_loc.trailingEllipsis)
                      const TextSpan(text: '\n\n…'),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The rendered window: text before the quote, the quote itself, and text after.
class _Located {
  const _Located({
    required this.found,
    required this.before,
    required this.highlight,
    required this.after,
    required this.leadingEllipsis,
    required this.trailingEllipsis,
  });
  const _Located.empty()
      : found = false,
        before = '',
        highlight = '',
        after = '',
        leadingEllipsis = false,
        trailingEllipsis = false;

  final bool found;
  final String before;
  final String highlight;
  final String after;
  final bool leadingEllipsis;
  final bool trailingEllipsis;
}
