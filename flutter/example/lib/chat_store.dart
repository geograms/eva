import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

/// Summary row for the conversation drawer.
class ConversationInfo {
  ConversationInfo({
    required this.id,
    required this.title,
    required this.updatedAt,
  });
  final int id;
  final String title;
  final DateTime updatedAt;
}

/// One persisted chat message.
class StoredMessage {
  StoredMessage({
    required this.role,
    required this.text,
    this.imagePath,
    this.sources,
  });
  final String role;
  final String text;
  final String? imagePath;
  final List<String>? sources;
}

/// SQLite-backed chat history (conversations + messages) so chats survive app
/// restarts. Lives in the app documents directory — separate from the document
/// corpus pack, which can sit on an SD card and travel between installs.
class ChatStore {
  ChatStore._(this._db);
  final Database _db;

  static ChatStore open(String path) {
    final db = sqlite3.open(path);
    db.execute('PRAGMA journal_mode=WAL;');
    db.execute('''
      CREATE TABLE IF NOT EXISTS conversations(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS messages(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conv_id INTEGER NOT NULL,
        role TEXT NOT NULL,
        text TEXT NOT NULL,
        image_path TEXT,
        sources TEXT,
        created_at TEXT NOT NULL
      );
    ''');
    db.execute(
        'CREATE INDEX IF NOT EXISTS idx_messages_conv ON messages(conv_id);');
    return ChatStore._(db);
  }

  int createConversation(String title) {
    final now = DateTime.now().toIso8601String();
    _db.execute(
      'INSERT INTO conversations(title, created_at, updated_at) VALUES(?,?,?);',
      [title, now, now],
    );
    return _db.lastInsertRowId;
  }

  void renameConversation(int id, String title) => _db.execute(
      'UPDATE conversations SET title=? WHERE id=?;', [title, id]);

  void deleteConversation(int id) {
    _db.execute('DELETE FROM messages WHERE conv_id=?;', [id]);
    _db.execute('DELETE FROM conversations WHERE id=?;', [id]);
  }

  List<ConversationInfo> listConversations() {
    final rs = _db.select(
        'SELECT id, title, updated_at FROM conversations ORDER BY updated_at DESC;');
    return [
      for (final r in rs)
        ConversationInfo(
          id: r['id'] as int,
          title: r['title'] as String,
          updatedAt:
              DateTime.tryParse(r['updated_at'] as String) ?? DateTime.now(),
        )
    ];
  }

  /// Id of the most recently active conversation, or null when none exist.
  int? latestConversationId() {
    final rs = _db.select(
        'SELECT id FROM conversations ORDER BY updated_at DESC LIMIT 1;');
    return rs.isEmpty ? null : rs.first['id'] as int;
  }

  void addMessage(int convId, StoredMessage m) {
    final now = DateTime.now().toIso8601String();
    _db.execute(
      'INSERT INTO messages(conv_id, role, text, image_path, sources, created_at) '
      'VALUES(?,?,?,?,?,?);',
      [
        convId,
        m.role,
        m.text,
        m.imagePath,
        m.sources == null ? null : jsonEncode(m.sources),
        now,
      ],
    );
    _db.execute(
        'UPDATE conversations SET updated_at=? WHERE id=?;', [now, convId]);
  }

  List<StoredMessage> messages(int convId) {
    final rs = _db.select(
      'SELECT role, text, image_path, sources FROM messages '
      'WHERE conv_id=? ORDER BY id;',
      [convId],
    );
    return [
      for (final r in rs)
        StoredMessage(
          role: r['role'] as String,
          text: r['text'] as String,
          imagePath: r['image_path'] as String?,
          sources: r['sources'] == null
              ? null
              : (jsonDecode(r['sources'] as String) as List).cast<String>(),
        )
    ];
  }

  void close() => _db.dispose();
}
