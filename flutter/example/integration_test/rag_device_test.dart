// On-device verification of the Phase 3 / 3b document-retrieval pipeline.
//
// Runs the REAL stack on the connected Android device: the arm64 native
// `libcactus.so` (usearch int8 + the nomic embedder) plus the Dart sharding,
// background indexer and hybrid query. It is deterministic (assertions, no UI
// taps or screenshots), so it sidesteps the flaky on-screen automation.
//
//   flutter test integration_test/rag_device_test.dart -d <deviceId>
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:cactus_example/app_prefs.dart';
import 'package:cactus_example/background_indexer.dart';
import 'package:cactus_example/document_service.dart';
import 'package:cactus_example/inference_isolate.dart';
import 'package:cactus_example/model_catalog.dart';
import 'package:cactus_example/model_manager.dart';
import 'package:cactus_example/rag_index.dart';

// A document whose chunks comfortably exceed a tiny shard capacity, so indexing
// it forces several shards (the new sharded layout).
String _doc(String topic, String fact) {
  final b = StringBuffer();
  for (var p = 1; p <= 4; p++) {
    b.writeln('[Page $p]');
    b.writeln('This page $p discusses $topic in detail. $fact '
        'It elaborates with several sentences so the chunker emits a chunk per '
        'page, each carrying distinctive content about $topic for retrieval. '
        '${'Filler context about $topic. ' * 8}');
  }
  return b.toString();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final engine = InferenceEngine();
  late Directory tmpRoot;

  setUpAll(() async {
    await engine.start();
    final dir = await ModelManager().ensureInstalled(kEmbedderModel, (_, _) {});
    await engine.loadEmbedder(dir);
    final docs = await getApplicationDocumentsDirectory();
    tmpRoot = Directory('${docs.path}/itest_${DateTime.now().millisecondsSinceEpoch}');
    await tmpRoot.create(recursive: true);
  });

  tearDownAll(() async {
    if (await tmpRoot.exists()) await tmpRoot.delete(recursive: true);
  });

  test('sharded int8 index: build, query, persist across reopen', () async {
    final packDir = '${tmpRoot.path}/pack';
    var rag = await RagIndex.open(packDir, shardCapacity: 3);

    await rag.addDocument(
      docId: 'alpha',
      name: 'alpha.txt',
      fullText: _doc('photosynthesis',
          'Chlorophyll absorbs light to convert water and carbon dioxide into glucose.'),
      embed: engine.embedBatch,
    );
    await rag.addDocument(
      docId: 'beta',
      name: 'beta.txt',
      fullText: _doc('volcanoes',
          'Magma rises through the crust and erupts as lava during an eruption.'),
      embed: engine.embedBatch,
    );

    // Small capacity + many chunks must have rolled into multiple shards, and
    // every chunk must have a vector.
    debugPrint('ITEST shards=${rag.shardCount} '
        'chunks=${rag.chunkCount} vectors=${rag.vectorCount}');
    expect(rag.shardCount, greaterThan(1), reason: 'expected shard rollover');
    expect(rag.vectorCount, rag.chunkCount);
    expect(rag.indexedDocIds, containsAll(<String>{'alpha', 'beta'}));

    // Semantic query about alpha's topic must retrieve alpha's chunks (the real
    // embedder + cross-shard merge picking the right document).
    final qv = (await engine.embedBatch(['How do plants make sugar from sunlight?'])).first;
    final hits = await rag.query(
        queryVec: qv, queryText: 'plants sunlight sugar', topK: 3);
    debugPrint('ITEST hits=${hits.map((h) => h.docName).toList()}');
    expect(hits, isNotEmpty);
    expect(hits.first.docName, 'alpha.txt');

    // Reopen the pack: sealed shards load memory-mapped, the active shard loads
    // into RAM — retrieval must survive the round trip.
    rag.close();
    rag = await RagIndex.open(packDir, shardCapacity: 3);
    expect(rag.vectorCount, rag.chunkCount);
    final hits2 = await rag.query(
        queryVec: qv, queryText: 'plants sunlight sugar', topK: 3);
    expect(hits2.first.docName, 'alpha.txt');
    rag.close();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('background indexer drains the backlog (throttled, resumable)', () async {
    // Point DocumentService at an isolated corpus so the test does not touch the
    // user's real archive; restore the original location afterwards.
    final originalLoc = await loadCorpusLocation();
    final corpus = '${tmpRoot.path}/corpus';
    await Directory(corpus).create(recursive: true);
    await saveCorpusLocation(corpus);
    addTearDown(() => saveCorpusLocation(originalLoc));

    final docs = DocumentService();
    for (final name in ['notes_a', 'notes_b', 'notes_c']) {
      final src = File('${tmpRoot.path}/$name.txt');
      await src.writeAsString(_doc(name, 'Distinctive fact for $name about $name.'));
      await docs.addFile(src.path);
    }

    final rag = await RagIndex.open(corpus, shardCapacity: 4);
    final indexer = IndexingController(docs, engine.embedBatch)..bind(rag);
    await indexer.run(); // drives the whole backlog to completion

    final all = await docs.list();
    debugPrint('ITEST indexer processed=${indexer.processed}/${indexer.total} '
        'indexed=${rag.indexedDocIds.length} shards=${rag.shardCount}');
    expect(indexer.isIndexing, isFalse);
    expect(indexer.lastError, isNull);
    expect(rag.indexedDocIds, hasLength(all.length));
    expect(rag.vectorCount, rag.chunkCount);

    final qv = (await engine.embedBatch(['fact about notes_b'])).first;
    final hits = await rag.query(
        queryVec: qv, queryText: 'distinctive notes_b', topK: 3);
    expect(hits, isNotEmpty);
    rag.close();
    indexer.dispose();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
