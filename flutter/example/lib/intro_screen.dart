import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'app_prefs.dart';
import 'model_manager.dart';

/// First-run intro: explains what Eva will download and which permissions it
/// asks for, and (optionally) lets the user pick a folder where models are
/// stored — e.g. an SD card — so downloads survive a reinstall and an existing
/// folder is reused instead of re-downloaded. Shown once per install.
class IntroScreen extends StatefulWidget {
  const IntroScreen({super.key, required this.onDone});

  /// Called when the user taps Continue (after the choice is persisted).
  final VoidCallback onDone;

  @override
  State<IntroScreen> createState() => _IntroScreenState();
}

class _IntroScreenState extends State<IntroScreen> {
  String _modelsLocation = '';
  int _foundModels = 0;
  bool _picking = false;

  Future<void> _chooseFolder() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      // Shared storage (SD card) needs all-files access to create the folder.
      var status = await Permission.manageExternalStorage.status;
      if (!status.isGranted) {
        status = await Permission.manageExternalStorage.request();
      }
      if (!status.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'Storage permission is needed to use a custom folder.')));
        }
        return;
      }
      final dir = await FilePicker.platform.getDirectoryPath();
      if (dir == null) return;
      await saveModelsLocation(dir);
      final found = await ModelManager().countModelsAt(dir);
      if (mounted) {
        setState(() {
          _modelsLocation = dir;
          _foundModels = found;
        });
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _useDefault() async {
    await saveModelsLocation('');
    if (mounted) {
      setState(() {
        _modelsLocation = '';
        _foundModels = 0;
      });
    }
  }

  Widget _item(IconData icon, String title, String body) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(body,
                    style: TextStyle(
                        fontSize: 13, color: Colors.grey.shade600)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 4),
        child: Text(title,
            style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
                children: [
                  const Center(
                    child: CircleAvatar(
                      radius: 44,
                      backgroundImage: AssetImage('assets/eva.png'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: Text('Welcome to Eva',
                        style: Theme.of(context).textTheme.headlineSmall),
                  ),
                  const SizedBox(height: 4),
                  const Center(
                    child: Text(
                      'A private assistant that runs entirely on this phone.\n'
                      'No account, no cloud — your data never leaves the device.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                  _section('What Eva downloads (one time)'),
                  _item(
                      Icons.chat_bubble_outline,
                      'Chat model — about 0.2 GB',
                      'Downloaded on first launch. Larger or vision models are '
                          'only downloaded if you select them.'),
                  _item(
                      Icons.description_outlined,
                      'Document search — about 0.2 GB',
                      'Only when you attach your first document (PDF/text).'),
                  _item(
                      Icons.mic_none,
                      'Offline English voice — about 60 MB',
                      'Optional. You can instead use the phone\'s own speech '
                          'recognition with no download.'),
                  _section('Permissions Eva may ask for'),
                  _item(
                      Icons.mic,
                      'Microphone',
                      'To talk to Eva — in the chat and when used as the '
                          'phone\'s assistant. Audio is processed on-device.'),
                  _item(
                      Icons.folder_outlined,
                      'File access',
                      'Only if you store models or documents in a folder of '
                          'your choice (e.g. an SD card).'),
                  _section('Keep models across reinstalls (optional)'),
                  Text(
                    _modelsLocation.isEmpty
                        ? 'Models are stored inside the app by default and are '
                            'deleted if the app is uninstalled. Choose a folder '
                            '(e.g. on the SD card) to keep them — if Eva finds '
                            'models there, nothing is downloaded again.'
                        : 'Models folder: $_modelsLocation'
                            '${_foundModels > 0 ? '\nFound $_foundModels model'
                                '${_foundModels == 1 ? '' : 's'} here — they '
                                'will be reused, no re-download.' : ''}',
                    style:
                        TextStyle(fontSize: 13, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: _picking ? null : _chooseFolder,
                        icon: const Icon(Icons.folder_open, size: 18),
                        label: Text(_modelsLocation.isEmpty
                            ? 'Choose folder…'
                            : 'Change folder…'),
                      ),
                      if (_modelsLocation.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: _useDefault,
                          child: const Text('Use app storage'),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () async {
                    await saveIntroSeen();
                    widget.onDone();
                  },
                  child: const Text('Continue'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
