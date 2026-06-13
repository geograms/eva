// Minimal C ABI shim over libzim (C++), so Dart's dart:ffi can drive an offline
// ZIM (Kiwix Wikipedia) archive: open, full-text/title search, and raw entry
// fetch for the in-app reader. Search results are returned as a small JSON
// string to keep the FFI surface trivial (no struct-array marshalling).
//
// libzim itself (Xapian full-text index + zstd/lzma decompression + ICU
// tokenisation) is statically bundled in the prebuilt libzim.so we link against.

#include <zim/archive.h>
#include <zim/search.h>
#include <zim/suggestion.h>
#include <zim/entry.h>
#include <zim/item.h>
#include <zim/blob.h>

#include <cstdlib>
#include <cstring>
#include <string>

extern "C" {

struct zimffi_archive {
  zim::Archive archive;
  explicit zimffi_archive(const char* path) : archive(path) {}
};

// Point ICU at its data directory (the Android libzim ships icudt*.dat
// separately). Must be called before any search. No-op if dir is null/empty.
void zimffi_set_icu_data(const char* dir) {
  if (dir && *dir) setenv("ICU_DATA", dir, 1);
}

zimffi_archive* zimffi_open(const char* path) {
  try {
    return new zimffi_archive(path);
  } catch (...) {
    return nullptr;
  }
}

void zimffi_close(zimffi_archive* a) { delete a; }

int zimffi_has_fulltext(zimffi_archive* a) {
  if (!a) return 0;
  try {
    return a->archive.hasFulltextIndex() ? 1 : 0;
  } catch (...) {
    return 0;
  }
}

void zimffi_free(void* p) { free(p); }

// ── helpers ──────────────────────────────────────────────────────────────────

static void jsonEscape(const std::string& in, std::string& out) {
  for (char c : in) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (static_cast<unsigned char>(c) < 0x20) {
          char buf[8];
          snprintf(buf, sizeof(buf), "\\u%04x", c);
          out += buf;
        } else {
          out += c;
        }
    }
  }
}

static char* dup(const std::string& s) {
  char* out = static_cast<char*>(malloc(s.size() + 1));
  if (out) memcpy(out, s.c_str(), s.size() + 1);
  return out;
}

// ── search ───────────────────────────────────────────────────────────────────

// Full-text search → JSON array of {path,title,score,snippet}. Returns "[]" on
// any failure. Caller frees with zimffi_free.
char* zimffi_search(zimffi_archive* a, const char* query, int k) {
  std::string json = "[";
  if (a && query) {
    try {
      zim::Searcher searcher(a->archive);
      zim::Query q(query);
      auto search = searcher.search(q);
      auto results = search.getResults(0, k > 0 ? k : 5);
      bool first = true;
      for (auto it = results.begin(); it != results.end(); ++it) {
        if (!first) json += ",";
        first = false;
        std::string path, title, snippet;
        jsonEscape(it.getPath(), path);
        jsonEscape(it.getTitle(), title);
        jsonEscape(it.getSnippet(), snippet);
        json += "{\"path\":\"" + path + "\",\"title\":\"" + title +
                "\",\"score\":" + std::to_string(it.getScore()) +
                ",\"snippet\":\"" + snippet + "\"}";
      }
    } catch (...) {
      json = "[";
    }
  }
  json += "]";
  return dup(json);
}

// Title suggestion → JSON array of {path,title}. Caller frees.
char* zimffi_suggest(zimffi_archive* a, const char* query, int k) {
  std::string json = "[";
  if (a && query) {
    try {
      zim::SuggestionSearcher ss(a->archive);
      auto search = ss.suggest(query);
      auto results = search.getResults(0, k > 0 ? k : 5);
      bool first = true;
      for (auto it = results.begin(); it != results.end(); ++it) {
        if (!first) json += ",";
        first = false;
        std::string path, title;
        jsonEscape(it->getPath(), path);
        jsonEscape(it->getTitle(), title);
        json += "{\"path\":\"" + path + "\",\"title\":\"" + title + "\"}";
      }
    } catch (...) {
      json = "[";
    }
  }
  json += "]";
  return dup(json);
}

// ── content ──────────────────────────────────────────────────────────────────

// Path of the archive's landing page. Caller frees (may be empty).
char* zimffi_main_path(zimffi_archive* a) {
  std::string p;
  if (a) {
    try {
      if (a->archive.hasMainEntry()) p = a->archive.getMainEntry().getPath();
    } catch (...) {
    }
  }
  return dup(p);
}

// Fetches the raw bytes for an entry path (following redirects). Returns a
// malloc'd buffer (caller frees) and writes the byte length to *out_len and the
// mimetype to *out_mime (also malloc'd; caller frees). Returns null if missing.
unsigned char* zimffi_get(zimffi_archive* a, const char* path, char** out_mime,
                          int* out_len) {
  if (out_len) *out_len = 0;
  if (out_mime) *out_mime = nullptr;
  if (!a || !path) return nullptr;
  try {
    auto entry = a->archive.getEntryByPath(path);
    auto item = entry.getItem(true); // follow redirects
    auto blob = item.getData();
    const auto size = blob.size();
    auto* out = static_cast<unsigned char*>(malloc(size ? size : 1));
    if (!out) return nullptr;
    memcpy(out, blob.data(), size);
    if (out_len) *out_len = static_cast<int>(size);
    if (out_mime) *out_mime = dup(item.getMimetype());
    return out;
  } catch (...) {
    return nullptr;
  }
}

} // extern "C"
