// Language-neutral text helpers for the grounding heuristics (which documents /
// Wikipedia articles are relevant to a query). Eva is multilingual, so these
// must not rely on English-only rules. We keep a compact stopword set spanning
// the languages Eva is most likely to see (EN, PT, ES, FR, IT, DE) plus a
// length filter, and a trailing-`s` singular fallback (plural marker shared by
// EN/PT/ES/FR/IT).

/// Common function / question words across several languages. Used to drop
/// non-meaningful words when extracting a query's keywords. Not `const`: the
/// per-language lists deliberately overlap, and a `final` set dedupes them.
final Set<String> kStopwords = {
  // English
  'the', 'and', 'for', 'are', 'was', 'were', 'who', 'what', 'whats', 'where',
  'when', 'why', 'how', 'does', 'did', 'can', 'could', 'would', 'should',
  'about', 'with', 'from', 'that', 'this', 'tell', 'give', 'explain', 'their',
  'them', 'they', 'you', 'your', 'has', 'have', 'had', 'into', 'some', 'any',
  'please', 'more', 'much', 'many', 'which', 'whose', 'over', 'than', 'there',
  'here', 'his', 'her', 'its', 'our', 'out', 'not', 'but',
  // Portuguese
  'que', 'qual', 'quais', 'quem', 'onde', 'quando', 'porque', 'porquê', 'como',
  'para', 'por', 'com', 'sem', 'dos', 'das', 'uma', 'uns', 'umas', 'são', 'foi',
  'tem', 'sobre', 'isto', 'isso', 'aquilo', 'meu', 'minha', 'seu', 'sua', 'fale',
  'diga', 'explique', 'mais', 'muito', 'esse', 'essa', 'este', 'esta',
  // Spanish
  'qué', 'cuál', 'cuáles', 'quién', 'dónde', 'cuándo', 'cómo', 'porqué', 'con',
  'sin', 'los', 'las', 'una', 'unos', 'unas', 'son', 'fue', 'esto', 'eso',
  'aquello', 'más', 'muy', 'dime', 'explica',
  // French
  'quoi', 'quel', 'quelle', 'qui', 'où', 'comment', 'pourquoi', 'pour', 'avec',
  'sans', 'les', 'des', 'sont', 'était', 'sur', 'cela', 'plus', 'très', 'dis',
  // Italian / German (light)
  'che', 'chi', 'dove', 'perché', 'sono', 'der', 'die', 'und', 'wer',
  'wie', 'warum', 'über', 'mit', 'cosa',
};

/// Whether [text] looks like an information request (question), across the
/// supported languages. A trailing/embedded `?` covers every language; the cue
/// words cover statements like "tell me about…" / "fale-me sobre…".
final RegExp _questionCue = RegExp(
    r'^\s*(who|what|whats|where|when|why|how|which|whose|tell|explain|define|'
    r'describe|give|list|' // EN
    r'o que|que|qual|quais|quem|onde|quando|porque|como|fale|diga|explique|' // PT
    r'qué|cuál|cuáles|quién|dónde|cuándo|cómo|dime|explica|' // ES
    r'quoi|quel|quelle|qui|où|quand|comment|pourquoi|dis|explique|' // FR
    r'wer|was|wie|warum|wo|chi|cosa|dove|come|perché)\b',
    caseSensitive: false, unicode: true);

bool looksLikeQuestion(String text) {
  final s = text.trim();
  if (s.length < 4) return false;
  return s.contains('?') || _questionCue.hasMatch(s.toLowerCase());
}

/// Significant lowercase words of [text]: drops short words and [kStopwords],
/// and adds a singular form for trailing-`s` plurals so e.g. "UFOs" also matches
/// a source that says "UFO".
List<String> significantWords(String text) {
  final out = <String>{};
  for (final w in text
      .toLowerCase()
      .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
      .where((w) => w.length > 2 && !kStopwords.contains(w))) {
    out.add(w);
    if (w.length >= 4 && w.endsWith('s')) out.add(w.substring(0, w.length - 1));
  }
  return out.toList();
}
