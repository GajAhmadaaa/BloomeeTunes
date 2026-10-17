import 'dart:developer';
import 'dart:io';
import 'package:Bloomee/blocs/settings_cubit/cubit/settings_cubit.dart';
import 'package:Bloomee/screens/screen/home_views/setting_views/setting_shared_widgets.dart';
import 'package:Bloomee/screens/widgets/snackbar.dart';
import 'package:Bloomee/services/player/stream_cache/stream_cache_service.dart';
import 'package:Bloomee/services/storage_backup_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:Bloomee/core/theme/app_theme.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:Bloomee/l10n/app_localizations.dart';
import 'package:icons_plus/icons_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class BackupSettings extends StatelessWidget {
  const BackupSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: Default_Theme.themeColor,
      appBar: AppBar(
        backgroundColor: Default_Theme.themeColor,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: Default_Theme.primaryColor1),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          l10n.storageSettingTitle,
          style: const TextStyle(
            color: Default_Theme.primaryColor1,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ).merge(Default_Theme.secondoryTextStyle),
        ),
      ),
      body: BlocBuilder<SettingsCubit, SettingsState>(
        builder: (context, state) {
          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            children: [
              // ── Stream cache ─────────────────────────────────────────
              const _StreamCacheSection(),

              // ── History ──────────────────────────────────────────────
              SettingSectionHeader(label: l10n.settingsHistory),
              SettingCard(
                children: [
                  SettingDropdownTile<String>(
                    icon: MingCute.history_line,
                    title: l10n.storageClearHistoryEvery,
                    subtitle: l10n.storageClearHistorySubtitle,
                    value: state.historyClearTime,
                    items: ['3', '7', '14', '30', '60', '90', '180', '365']
                        .map((v) => SettingDropdownItem<String>(
                              value: v,
                              label: l10n.storageDays(int.parse(v)),
                            ))
                        .toList(),
                    onChanged: (newValue) {
                      if (newValue != null) {
                        context
                            .read<SettingsCubit>()
                            .setHistoryClearTime(newValue);
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // ── Backup & Restore ──────────────────────────────────────
              SettingSectionHeader(label: l10n.settingsBackupRestore),
              SettingCard(
                children: [
                  Column(
                    children: [
                      SettingNavTile(
                        icon: MingCute.folder_info_line,
                        title: l10n.storageBackupLocation,
                        subtitle: Platform.isAndroid
                            ? l10n.storageBackupLocationAndroid
                            : (state.backupPath.isNotEmpty
                                ? state.backupPath
                                : l10n.storageBackupLocationDownloads),
                        onTap: () => showDialog(
                          context: context,
                          builder: (_) => _BackupLocationDialog(),
                        ),
                      ),
                      const SettingDivider(),
                      SettingNavTile(
                        icon: MingCute.save_2_line,
                        title: l10n.storageCreateBackup,
                        subtitle: l10n.storageCreateBackupSubtitle,
                        onTap: () {
                          StorageBackupService.createBackup().then((value) {
                            if (value != null) {
                              SnackbarService.showMessage(
                                  l10n.storageBackupCreatedAt(value));
                              if (Platform.isAndroid) {
                                try {
                                  SharePlus.instance
                                      .share(ShareParams(
                                    files: [XFile(value)],
                                    text: 'Bloomee backup file',
                                    subject: 'Bloomee Backup',
                                  ))
                                      .catchError((e) {
                                    SnackbarService.showMessage(
                                        l10n.storageBackupShareFailed(
                                            e.toString()));
                                    return ShareResult.unavailable;
                                  });
                                } catch (e) {
                                  SnackbarService.showMessage(l10n
                                      .storageBackupShareFailed(e.toString()));
                                }
                              }
                            } else {
                              SnackbarService.showMessage(
                                  l10n.storageBackupFailed);
                            }
                          });
                        },
                      ),
                      const SettingDivider(),
                      SettingNavTile(
                        icon: MingCute.file_export_line,
                        title: '${l10n.storageCreateBackup} (JSON)',
                        subtitle:
                            'Export a portable JSON backup for migration/import.',
                        onTap: () {
                          StorageBackupService.createJsonBackup().then((value) {
                            if (value != null) {
                              SnackbarService.showMessage(
                                  l10n.storageBackupCreatedAt(value));
                              if (Platform.isAndroid) {
                                try {
                                  SharePlus.instance
                                      .share(ShareParams(
                                    files: [XFile(value)],
                                    text: 'Bloomee JSON backup file',
                                    subject: 'Bloomee JSON Backup',
                                  ))
                                      .catchError((e) {
                                    SnackbarService.showMessage(
                                        l10n.storageBackupShareFailed(
                                            e.toString()));
                                    return ShareResult.unavailable;
                                  });
                                } catch (e) {
                                  SnackbarService.showMessage(l10n
                                      .storageBackupShareFailed(e.toString()));
                                }
                              }
                            } else {
                              SnackbarService.showMessage(
                                  l10n.storageBackupFailed);
                            }
                          });
                        },
                      ),
                      const SettingDivider(),
                      SettingNavTile(
                        icon: MingCute.restore_line,
                        title: l10n.storageRestoreBackup,
                        subtitle: l10n.storageRestoreBackupSubtitle,
                        onTap: () => _onRestoreTap(context),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // ── Automatic ─────────────────────────────────────────────
              SettingSectionHeader(label: l10n.settingsAutomatic),
              SettingCard(
                children: [
                  SettingToggleTile(
                    icon: MingCute.time_fill,
                    title: l10n.storageAutoBackup,
                    subtitle: l10n.storageAutoBackupSubtitle,
                    value: state.autoBackup,
                    onChanged: (value) =>
                        context.read<SettingsCubit>().setAutoBackup(value),
                  ),
                  const SettingDivider(),
                  SettingToggleTile(
                    icon: MingCute.music_2_line,
                    title: l10n.storageAutoLyrics,
                    subtitle: l10n.storageAutoLyricsSubtitle,
                    value: state.autoSaveLyrics,
                    onChanged: (value) =>
                        context.read<SettingsCubit>().setAutoSaveLyrics(value),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // ── Danger Zone ───────────────────────────────────────────
              SettingSectionHeader(label: l10n.settingsDangerZone),
              SettingCard(
                children: [
                  SettingDestructiveTile(
                    icon: MingCute.delete_2_fill,
                    title: l10n.storageResetApp,
                    subtitle: l10n.storageResetAppSubtitle,
                    onTap: () async {
                      final proceed = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          backgroundColor:
                              const Color.fromARGB(255, 24, 24, 24),
                          surfaceTintColor:
                              const Color.fromARGB(255, 24, 24, 24),
                          title: Text(
                            l10n.storageResetConfirmTitle,
                            style: Default_Theme.secondoryTextStyle.merge(
                              const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                          content: Text(
                            l10n.storageResetConfirmMessage,
                            style: Default_Theme.secondoryTextStyle.merge(
                              const TextStyle(
                                  color: Colors.white, fontSize: 14),
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(ctx).pop(false),
                              child: Text(l10n.buttonCancel,
                                  style: Default_Theme.secondoryTextStyle.merge(
                                      const TextStyle(color: Colors.white))),
                            ),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.red.shade700),
                              onPressed: () => Navigator.of(ctx).pop(true),
                              child: Text(l10n.storageResetButton,
                                  style: const TextStyle(color: Colors.white)),
                            ),
                          ],
                        ),
                      );
                      if (proceed == true) {
                        await StorageBackupService.resetAppData();
                        SnackbarService.showMessage(l10n.storageResetSuccess);
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }
}

class _BackupLocationDialog extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      backgroundColor: const Color.fromARGB(255, 24, 24, 24),
      surfaceTintColor: const Color.fromARGB(255, 24, 24, 24),
      title: Text(
        l10n.storageLocationDialogTitle,
        style: Default_Theme.secondoryTextStyle.merge(
            const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      content: Text(
        Platform.isAndroid
            ? l10n.storageLocationAndroid
            : l10n.storageLocationOther,
        style: Default_Theme.secondoryTextStyle
            .merge(const TextStyle(color: Colors.white, fontSize: 14)),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.buttonOk,
              style: Default_Theme.secondoryTextStyle.merge(const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold))),
        ),
      ],
    );
  }
}

Future<void> _onRestoreTap(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  try {
    // 1) Ask user to pick a file (using FileType.any so that custom extensions like .isar / .db are not grayed out on Android)
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      withData: false,
      type: FileType.any,
    );

    if (result == null || result.files.isEmpty) {
      SnackbarService.showMessage(l10n.storageRestoreNoFile);
      return;
    }

    final picked = result.files.first;

    // 2) Save the picked file to internal documents directory
    final savedPath = await _savePickedFileToInternalDir(picked);
    if (savedPath == null) {
      SnackbarService.showMessage(l10n.storageRestoreSaveFailed);
      return;
    }

    // 3) Show options dialog: which parts to restore (defaults all true)
    final options = await showDialog<_RestoreOptions?>(
      context: context,
      builder: (ctx) {
        // initial values (all true)
        bool mediaItems = true;
        bool searchHistory = true;
        bool settingsAndPrefs = true;
        bool selectAll = true;

        return StatefulBuilder(builder: (ctx2, setState) {
          void updateSelectAllFromChildren() {
            final all = mediaItems && searchHistory && settingsAndPrefs;
            if (selectAll != all) setState(() => selectAll = all);
          }

          void toggleSelectAll(bool? v) {
            final value = v == true;
            setState(() {
              selectAll = value;
              mediaItems = value;
              searchHistory = value;
              settingsAndPrefs = value;
            });
          }

          return AlertDialog(
            backgroundColor: const Color.fromARGB(255, 24, 24, 24),
            title: Text(l10n.storageRestoreOptionsTitle,
                style: Default_Theme.secondoryTextStyle
                    .merge(const TextStyle(color: Colors.white))),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l10n.storageRestoreOptionsDesc,
                    style: Default_Theme.secondoryTextStyle.merge(
                        const TextStyle(color: Colors.white70, fontSize: 13)),
                  ),
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    value: selectAll,
                    onChanged: toggleSelectAll,
                    title: Text(l10n.storageRestoreSelectAll,
                        style: Default_Theme.secondoryTextStyle
                            .merge(const TextStyle(color: Colors.white))),
                    controlAffinity: ListTileControlAffinity.leading,
                    activeColor: Default_Theme.accentColor2,
                    checkColor: Colors.white,
                  ),
                  const Divider(color: Colors.white12),
                  CheckboxListTile(
                    value: mediaItems,
                    onChanged: (v) {
                      setState(() => mediaItems = v ?? false);
                      updateSelectAllFromChildren();
                    },
                    title: Text(l10n.storageRestoreMediaItems,
                        style: Default_Theme.secondoryTextStyle
                            .merge(const TextStyle(color: Colors.white))),
                    controlAffinity: ListTileControlAffinity.leading,
                    activeColor: Default_Theme.accentColor2,
                    checkColor: Colors.white,
                  ),
                  CheckboxListTile(
                    value: searchHistory,
                    onChanged: (v) {
                      setState(() => searchHistory = v ?? false);
                      updateSelectAllFromChildren();
                    },
                    title: Text(l10n.storageRestoreSearchHistory,
                        style: Default_Theme.secondoryTextStyle
                            .merge(const TextStyle(color: Colors.white))),
                    controlAffinity: ListTileControlAffinity.leading,
                    activeColor: Default_Theme.accentColor2,
                    checkColor: Colors.white,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx2).pop(null),
                child: Text(l10n.buttonCancel,
                    style: Default_Theme.secondoryTextStyle
                        .merge(const TextStyle(color: Colors.white))),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: Default_Theme.accentColor2),
                onPressed: () {
                  Navigator.of(ctx2).pop(_RestoreOptions(
                    restoreMediaItems: mediaItems,
                    restoreSearchHistory: searchHistory,
                    restoreSettings: settingsAndPrefs,
                  ));
                },
                child: Text(l10n.storageRestoreContinue,
                    style: Default_Theme.secondoryTextStyle
                        .merge(const TextStyle(color: Colors.white))),
              ),
            ],
          );
        });
      },
    );

    // If user cancelled options dialog
    if (options == null) return;

    // 4) Show final confirmation with warning (user must confirm)
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color.fromARGB(255, 24, 24, 24),
          title: Text(l10n.storageRestoreConfirmTitle,
              style: Default_Theme.secondoryTextStyle.merge(const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold))),
          content: Text(
            "${l10n.storageRestoreConfirmPrefix}\n\n"
            "${options.restoreMediaItems ? "${l10n.storageRestoreMediaBullet}\n" : ""}"
            "${options.restoreSearchHistory ? "${l10n.storageRestoreHistoryBullet}\n" : ""}"
            "\n${l10n.storageRestoreConfirmSuffix}",
            style: Default_Theme.secondoryTextStyle
                .merge(const TextStyle(color: Colors.white70, fontSize: 14)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.storageRestoreNo,
                  style: Default_Theme.secondoryTextStyle
                      .merge(const TextStyle(color: Colors.white))),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: Default_Theme.accentColor2),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l10n.storageRestoreYes,
                  style: Default_Theme.secondoryTextStyle
                      .merge(const TextStyle(color: Colors.white))),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      // user cancelled final confirmation
      return;
    }

    // 5) Show non-dismissible progress dialog and capture its context
    BuildContext? progressDialogContext;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        progressDialogContext = ctx; // capture
        return WillPopScope(
          onWillPop: () async => false,
          child: AlertDialog(
            backgroundColor: const Color.fromARGB(255, 24, 24, 24),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(
                  l10n.storageRestoring,
                  textAlign: TextAlign.center,
                  style: Default_Theme.secondoryTextStyle
                      .merge(const TextStyle(color: Colors.white)),
                ),
              ],
            ),
          ),
        );
      },
    );

    // 6) Execute restore (guarantee progress dialog closed in finally)
    Map<String, dynamic> restoreResult = {
      "success": false,
      "error": "Restore not executed."
    };
    try {
      // NOTE: This call must be async and ideally run heavy work inside its own isolates.
      // Signature: restoreDB(path, settings, searchHistory, mediaitems)
      restoreResult = await StorageBackupService.restoreBackup(
        savedPath,
        options: options.toBackupOptions(),
      );
    } catch (e, st) {
      log("restoreDB threw: $e\n$st", name: "DBProvider");
      restoreResult = {
        "success": false,
        "error": "Exception during restore: $e"
      };
    } finally {
      // Always attempt to close the progress dialog using captured context
      if (progressDialogContext != null) {
        try {
          if (Navigator.of(progressDialogContext!).canPop()) {
            Navigator.of(progressDialogContext!).pop();
          }
        } catch (e) {
          log("Failed to pop progress dialog: $e", name: "StorageSetting");
        }
      } else {
        // Fallback: try to pop root navigator (best-effort)
        try {
          if (Navigator.of(context, rootNavigator: true).canPop()) {
            Navigator.of(context, rootNavigator: true).pop();
          }
        } catch (_) {}
      }
      // allow UI a short moment to settle
      await Future.delayed(const Duration(milliseconds: 150));
    }

    // 7) Show final result dialog and recommend restart
    final success = restoreResult["success"] == true;
    final errors = <String>[];
    if (restoreResult.containsKey("errors")) {
      final raw = restoreResult["errors"];
      if (raw is List) {
        errors.addAll(raw.map((e) => e.toString()));
      } else if (raw != null) {
        errors.add(raw.toString());
      }
    }
    if (restoreResult.containsKey("error")) {
      final raw = restoreResult["error"];
      if (raw != null && raw.toString().trim().isNotEmpty) {
        errors.add(raw.toString());
      }
    }

    await _showResultDialog(context, success: success, errors: errors);
  } catch (e, st) {
    log("Unexpected error in restore flow: $e\n$st", name: "StorageSetting");
    SnackbarService.showMessage(l10n.storageUnexpectedError);
  }
}

/// Simple holder for options selected in options dialog
class _RestoreOptions {
  final bool restoreMediaItems;
  final bool restoreSearchHistory;
  final bool restoreSettings;

  _RestoreOptions({
    required this.restoreMediaItems,
    required this.restoreSearchHistory,
    required this.restoreSettings,
  });

  RestoreBackupOptions toBackupOptions() {
    return RestoreBackupOptions(
      restoreMediaItems: restoreMediaItems,
      restoreSearchHistory: restoreSearchHistory,
      restoreSettings: restoreSettings,
    );
  }
}

/// Save the picked file to app documents directory so the app retains access.
/// Returns saved file path or null.
Future<String?> _savePickedFileToInternalDir(PlatformFile picked) async {
  try {
    final docs = await getApplicationDocumentsDirectory();
    final safeName = picked.name.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    final filename =
        'bloomee_restore_${DateTime.now().millisecondsSinceEpoch}_$safeName';
    final dest = File('${docs.path}/$filename');

    if (picked.bytes != null) {
      await dest.writeAsBytes(picked.bytes!, flush: true);
      return dest.path;
    }

    if (picked.path != null) {
      final source = File(picked.path!);
      await source.copy(dest.path);
      return dest.path;
    }

    return null;
  } catch (e, st) {
    log("Failed to save picked file: $e\n$st", name: "StorageSetting");
    return null;
  }
}

/// Show final result dialog. Asks user to restart for best consistency.
Future<void> _showResultDialog(
  BuildContext context, {
  required bool success,
  required List<String> errors,
}) async {
  final l10n = AppLocalizations.of(context)!;
  await showDialog(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        backgroundColor: const Color.fromARGB(255, 24, 24, 24),
        title: Text(
          success
              ? l10n.storageRestoreCompleted
              : l10n.storageRestoreFailedTitle,
          style: Default_Theme.secondoryTextStyle.merge(const TextStyle(
              color: Colors.white, fontWeight: FontWeight.bold)),
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                success
                    ? l10n.storageRestoreSuccessMessage
                    : l10n.storageRestoreFailedMessage,
                style: Default_Theme.secondoryTextStyle
                    .merge(const TextStyle(color: Colors.white)),
              ),
              const SizedBox(height: 12),
              if (!success && errors.isNotEmpty)
                ...errors.map((e) => Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: Text(
                        "- $e",
                        style: Default_Theme.secondoryTextStyle.merge(
                            const TextStyle(
                                color: Colors.white70, fontSize: 13)),
                      ),
                    )),
              if (!success && errors.isEmpty)
                Text(
                  l10n.storageRestoreUnknownError,
                  style: Default_Theme.secondoryTextStyle
                      .merge(const TextStyle(color: Colors.white70)),
                ),
              const SizedBox(height: 8),
              Text(
                l10n.storageRestoreRestartHint,
                style: Default_Theme.secondoryTextStyle.merge(
                    const TextStyle(color: Colors.white54, fontSize: 12)),
              ),
            ],
          ),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Default_Theme.accentColor2),
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              l10n.buttonOk,
              style: Default_Theme.secondoryTextStyle.merge(const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      );
    },
  );
}

/// Stream-cache section: enable toggle, user-set size cap, usage, clear.
///
/// Note: strings here are plain English — the app's l10n files were not
/// regenerated (requires `flutter gen-l10n` at build time).
class _StreamCacheSection extends StatefulWidget {
  const _StreamCacheSection();

  @override
  State<_StreamCacheSection> createState() => _StreamCacheSectionState();
}

class _StreamCacheSectionState extends State<_StreamCacheSection> {
  int _usageNonce = 0;

  static const _capOptions = <String, String>{
    '256': '256 MB',
    '512': '512 MB',
    '1024': '1 GB',
    '2048': '2 GB',
    '5120': '5 GB',
    '10240': '10 GB',
    '0': 'Unlimited',
  };

  static const _maxFileOptions = <String, String>{
    '128': '128 MB',
    '256': '256 MB',
    '512': '512 MB',
    '1024': '1 GB',
    '2048': '2 GB',
    '0': 'Unlimited',
  };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingSectionHeader(label: 'Stream cache'),
        SettingCard(
          children: [
            BlocBuilder<SettingsCubit, SettingsState>(
              buildWhen: (p, c) =>
                  p.streamCacheEnabled != c.streamCacheEnabled ||
                  p.streamCacheCapMB != c.streamCacheCapMB ||
                  p.streamCacheMaxFileMB != c.streamCacheMaxFileMB,
              builder: (context, state) {
                return Column(
                  children: [
                    SettingToggleTile(
                      icon: Icons.cached,
                      title: 'Cache played songs',
                      subtitle:
                          'Save songs to disk as you stream them. Replays play from disk — no mobile data, works offline.',
                      value: state.streamCacheEnabled,
                      onChanged: (v) => context
                          .read<SettingsCubit>()
                          .setStreamCacheEnabled(v),
                    ),
                    const SettingDivider(),
                    SettingDropdownTile<String>(
                      icon: Icons.storage_outlined,
                      title: 'Cache size limit',
                      subtitle:
                          'When full, the least-recently-played songs are removed first.',
                      value: _capOptions.containsKey(state.streamCacheCapMB)
                          ? state.streamCacheCapMB
                          : '2048',
                      items: _capOptions.entries
                          .map((e) => SettingDropdownItem<String>(
                              value: e.key, label: e.value))
                          .toList(),
                      onChanged: (v) {
                        if (v != null) {
                          context.read<SettingsCubit>().setStreamCacheCapMB(v);
                        }
                      },
                    ),
                    const SettingDivider(),
                    SettingDropdownTile<String>(
                      icon: Icons.file_download_done_outlined,
                      title: 'Max song size',
                      subtitle:
                          'A single song bigger than this is not cached (it still plays normally).',
                      value: _maxFileOptions
                              .containsKey(state.streamCacheMaxFileMB)
                          ? state.streamCacheMaxFileMB
                          : '256',
                      items: _maxFileOptions.entries
                          .map((e) => SettingDropdownItem<String>(
                              value: e.key, label: e.value))
                          .toList(),
                      onChanged: (v) {
                        if (v != null) {
                          context
                              .read<SettingsCubit>()
                              .setStreamCacheMaxFileMB(v);
                        }
                      },
                    ),
                  ],
                );
              },
            ),
            const SettingDivider(),
            _CacheUsageTile(key: ValueKey(_usageNonce)),
            const SettingDivider(),
            SettingDestructiveTile(
              icon: Icons.delete_outline,
              title: 'Clear stream cache',
              subtitle: 'Delete all cached songs from disk.',
              onTap: () => _confirmClearCache(context),
            ),
          ],
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  Future<void> _confirmClearCache(BuildContext context) async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color.fromARGB(255, 24, 24, 24),
        surfaceTintColor: const Color.fromARGB(255, 24, 24, 24),
        title: Text(
          'Clear stream cache?',
          style: Default_Theme.secondoryTextStyle.merge(
            const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold),
          ),
        ),
        content: Text(
          'This deletes all cached songs from disk. Your downloads and library are not affected.',
          style: Default_Theme.secondoryTextStyle.merge(
            const TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Cancel',
                style: Default_Theme.secondoryTextStyle
                    .merge(const TextStyle(color: Colors.white))),
          ),
          ElevatedButton(
            style:
                ElevatedButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Clear', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (proceed != true) return;
    try {
      await StreamCacheService.instance.clear();
      if (mounted) setState(() => _usageNonce++);
      SnackbarService.showMessage('Stream cache cleared');
    } catch (e) {
      SnackbarService.showMessage('Failed to clear cache: $e');
    }
  }
}

class _CacheUsageTile extends StatelessWidget {
  const _CacheUsageTile({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<({int files, int bytes})>(
      future: StreamCacheService.instance.usage(),
      builder: (context, snap) {
        final u = snap.data;
        final subtitle = !StreamCacheService.instance.isRunning
            ? 'Cache service not running'
            : u == null
                ? 'Calculating…'
                : '${u.files} songs · ${_formatBytes(u.bytes)}';
        return SettingNavTile(
          icon: Icons.data_usage,
          title: 'Cache usage',
          subtitle: subtitle,
          onTap: () => _showCacheContents(context),
        );
      },
    );
  }

  void _showCacheContents(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1B1B1B),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => const _CacheContentsSheet(),
    );
  }
}

/// In-app cache forensics: what is actually on disk, biggest first.
/// Tap an entry to see where it was downloaded from.
class _CacheContentsSheet extends StatefulWidget {
  const _CacheContentsSheet();

  @override
  State<_CacheContentsSheet> createState() => _CacheContentsSheetState();
}

class _CacheContentsSheetState extends State<_CacheContentsSheet> {
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Cached songs',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.bug_report_outlined,
                      color: Colors.white70),
                  tooltip: 'Cache debug log',
                  onPressed: () => _showDebugLog(context),
                ),
              ],
            ),
            const SizedBox(height: 4),
            FutureBuilder<List<Map<String, dynamic>>>(
              future: StreamCacheService.instance.cacheEntries(),
              builder: (context, snap) {
                final entries = snap.data;
                if (entries == null) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                        child:
                            CircularProgressIndicator(color: Colors.white70)),
                  );
                }
                if (entries.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text('Cache is empty',
                          style: TextStyle(color: Colors.white70)),
                    ),
                  );
                }
                final total =
                    entries.fold<int>(0, (s, e) => s + (e['bytes'] as int));
                return Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${entries.length} songs · ${_formatBytes(total)} total',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 13),
                      ),
                      const SizedBox(height: 8),
                      Flexible(
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: entries.length,
                          separatorBuilder: (_, __) =>
                              const Divider(color: Colors.white12, height: 1),
                          itemBuilder: (context, i) {
                            final e = entries[i];
                            final date = (e['cachedAt'] as String)
                                .replaceFirst('T', ' ');
                            final shownDate =
                                date.length >= 16 ? date.substring(0, 16) : date;
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                              title: Text(
                                e['title'] as String,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 14),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${_formatBytes(e['bytes'] as int)}'
                                '${(e['quality'] as String).isNotEmpty ? ' · ${e['quality']}' : ''}'
                                '${shownDate.isEmpty ? '' : ' · $shownDate'}',
                                style: const TextStyle(
                                    color: Colors.white60, fontSize: 12),
                              ),
                              trailing: const Icon(Icons.chevron_right,
                                  color: Colors.white38, size: 20),
                              onTap: () => _showEntryDetails(
                                context,
                                e,
                                onDeleted: () {
                                  if (mounted) setState(() {});
                                },
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showDebugLog(BuildContext context) async {
    final logText = await StreamCacheService.instance.readDebugLog();
    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1B1B1B),
        title: const Text(
          'Cache debug log',
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: SingleChildScrollView(
            child: SelectableText(
              logText.isEmpty ? 'No log entries yet.' : logText,
              style: const TextStyle(color: Colors.white60, fontSize: 11),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await StreamCacheService.instance.clearDebugLog();
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Clear log',
                style: TextStyle(color: Colors.redAccent)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child:
                const Text('Close', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showEntryDetails(
      BuildContext context, Map<String, dynamic> e, {VoidCallback? onDeleted}) {
    final upstream = (e['upstream'] as String?) ?? '';
    final uri = Uri.tryParse(upstream);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1B1B1B),
        title: Text(
          e['title'] as String,
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _detailRow('Size', _formatBytes(e['bytes'] as int)),
              _detailRow('Type', (e['contentType'] as String).isEmpty
                  ? '—'
                  : e['contentType'] as String),
              _detailRow('Quality', (e['quality'] as String).isEmpty
                  ? '—'
                  : e['quality'] as String),
              _detailRow('Source host', uri?.host ?? '—'),
              const SizedBox(height: 8),
              const Text('Source URL',
                  style: TextStyle(color: Colors.white70, fontSize: 12)),
              const SizedBox(height: 4),
              SelectableText(
                upstream.isEmpty ? '— (cached before URL logging)' : upstream,
                style:
                    const TextStyle(color: Colors.white60, fontSize: 11),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: ctx,
                builder: (c2) => AlertDialog(
                  backgroundColor: const Color(0xFF1B1B1B),
                  title: const Text('Delete cached song?',
                      style: TextStyle(color: Colors.white, fontSize: 16)),
                  content: Text(
                      'Remove "${e['title']}" from the cache? It will be downloaded again next time you play it.',
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 13)),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(c2).pop(false),
                      child: const Text('Cancel',
                          style: TextStyle(color: Colors.white)),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(c2).pop(true),
                      child: const Text('Delete',
                          style: TextStyle(color: Colors.redAccent)),
                    ),
                  ],
                ),
              );
              if (confirm == true) {
                await StreamCacheService.instance
                    .deleteEntry(e['key'] as String);
                if (ctx.mounted) Navigator.of(ctx).pop();
                onDeleted?.call();
              }
            },
            child: const Text('Delete',
                style: TextStyle(color: Colors.redAccent)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(label,
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(color: Colors.white, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[u]}';
}
