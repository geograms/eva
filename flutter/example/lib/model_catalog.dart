import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A selectable on-device model. Cactus can only load *pre-transpiled* bundles
/// (config.txt + weights + components/manifest.json), so every entry points at a
/// bundle we produce in CI (embedded or downloaded) or one the user sideloads
/// from a folder on the device.
class ModelSpec {
  const ModelSpec({
    required this.id,
    required this.name,
    required this.sizeLabel,
    this.asset,
    this.url,
    this.localPath,
    this.isVision = false,
    this.isEmbedder = false,
  }) : assert(asset != null || url != null || localPath != null,
            'a model must come from an asset, a URL, or a local path');

  /// Stable id; also the on-device directory name under `models/<id>/`
  /// (download/asset models only).
  final String id;
  final String name;
  final String sizeLabel;

  /// Flutter asset path for a bundle embedded in the APK (the default model).
  final String? asset;

  /// URL of a pre-transpiled bundle zip (downloaded on demand).
  final String? url;

  /// Absolute path to an already-extracted model directory (sideloaded).
  final String? localPath;

  /// Whether this is a vision-language model that can answer questions about
  /// images. When true, the chat exposes a camera/gallery attach button.
  final bool isVision;

  /// Whether this is a text-embedding model used for document retrieval (RAG),
  /// not for chat. Embedding bundles have a `text_embedding` component instead
  /// of a decoder, so they validate against a lighter set of files.
  final bool isEmbedder;

  bool get isBundled => asset != null;
  bool get isSideloaded => localPath != null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'sizeLabel': sizeLabel,
        'localPath': localPath,
        'isVision': isVision,
      };

  static ModelSpec fromJson(Map<String, dynamic> j) => ModelSpec(
        id: j['id'] as String,
        name: j['name'] as String,
        sizeLabel: j['sizeLabel'] as String,
        localPath: j['localPath'] as String?,
        isVision: j['isVision'] as bool? ?? false,
      );
}

/// Built-in models. All are downloaded from the GitHub release on demand to
/// keep the APK small; the default is fetched automatically on first launch.
const List<ModelSpec> kBuiltinCatalog = [
  ModelSpec(
    id: 'lfm2.5-350m-int4',
    name: 'LFM2.5 350M (default)',
    sizeLabel: '~0.2 GB download',
    url: 'https://github.com/geograms/eva/releases/latest/download/lfm2.5-350m-int4-bundle.zip',
  ),
  ModelSpec(
    id: 'qwen3-1.7b-int4',
    name: 'Qwen3 1.7B',
    sizeLabel: '~1.1 GB download',
    url: 'https://github.com/geograms/eva/releases/latest/download/qwen3-1.7b-int4-bundle.zip',
  ),
  ModelSpec(
    id: 'lfm2-vl-450m-int4',
    name: 'LFM2-VL 450M · vision',
    sizeLabel: '~0.4 GB download · sees images',
    url: 'https://github.com/geograms/eva/releases/latest/download/lfm2-vl-450m-int4-bundle.zip',
    isVision: true,
  ),
  ModelSpec(
    id: 'lfm2.5-vl-1.6b-int4',
    name: 'LFM2.5-VL 1.6B · vision',
    sizeLabel: '~1.2 GB download · sees images, stronger',
    url: 'https://github.com/geograms/eva/releases/latest/download/lfm2.5-vl-1.6b-int4-bundle.zip',
    isVision: true,
  ),
];

const String kDefaultModelId = 'lfm2.5-350m-int4';

/// The multilingual text-embedding model that powers document retrieval (RAG).
/// Loaded alongside the chat model only when documents are present. Not shown
/// in the chat model list.
const ModelSpec kEmbedderModel = ModelSpec(
  id: 'nomic-embed-v2-int4',
  name: 'Document search (nomic-embed v2)',
  sizeLabel: '~0.2 GB download · multilingual',
  url: 'https://github.com/geograms/eva/releases/latest/download/nomic-embed-v2-int4-bundle.zip',
  isEmbedder: true,
);

/// Chat model recommended for document Q&A (better synthesis than the default).
const String kDocQaModelId = 'qwen3-1.7b-int4';

const String _kSideloadKey = 'sideloaded_models';

/// Sideloaded models the user added from a folder, persisted across launches.
Future<List<ModelSpec>> loadSideloadedModels() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getStringList(_kSideloadKey) ?? [];
  return raw
      .map((s) => ModelSpec.fromJson(jsonDecode(s) as Map<String, dynamic>))
      .toList();
}

Future<void> saveSideloadedModels(List<ModelSpec> models) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList(
    _kSideloadKey,
    models.map((m) => jsonEncode(m.toJson())).toList(),
  );
}

/// The full catalog = built-ins + sideloaded.
Future<List<ModelSpec>> loadCatalog() async =>
    [...kBuiltinCatalog, ...await loadSideloadedModels()];

ModelSpec modelById(List<ModelSpec> catalog, String id) =>
    catalog.firstWhere((m) => m.id == id, orElse: () => kBuiltinCatalog.first);
