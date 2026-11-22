import 'dart:convert';

import 'package:flutter/services.dart' show PlatformException;
import 'package:v2i_core/v2i_core.dart' as v2i;

import '../../core/network/api_exception.dart';
import '../../hardware/platform/hardware_platform.dart';
import '../data/v2i_repository.dart';

/// One file to export.
class ExportFile {
  ExportFile(this.name, this.mime, this.content);
  final String name;
  final String mime;
  final String content;
}

/// "v2i_Campus-gate_20261122-1030"
String exportBase(String session, DateTime at) {
  String two(int v) => v.toString().padLeft(2, '0');
  final safe = session.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  final name = safe.isEmpty ? 'session' : (safe.length > 40 ? safe.substring(0, 40) : safe);
  return 'v2i_${name}_${at.year}${two(at.month)}${two(at.day)}-${two(at.hour)}${two(at.minute)}';
}

/// The raw log, the per-second snapshots, every vehicle decision and the computed metrics.
List<ExportFile> sessionFiles(v2i.Recording r, v2i.Metrics m, v2i.ExportLabel label) {
  final base = exportBase(label.session, label.date);
  return [
    ExportFile('${base}_events.log', 'text/plain', v2i.eventLog(r, label)),
    ExportFile('${base}_snapshots.csv', 'text/csv', v2i.snapshotsCsv(r, label)),
    ExportFile('${base}_vehicles.csv', 'text/csv', v2i.samplesCsv(r, label)),
    ExportFile('${base}_metrics.csv', 'text/csv', v2i.metricsCsv(m, r, label)),
  ];
}

class ExportOutcome {
  final saved = <String>[];
  final uploaded = <String>[];
  final problems = <String>[];

  String get summary => [
        if (saved.isNotEmpty) 'Saved ${saved.length} file(s) to ${saved.first.contains('/') ? saved.first.substring(0, saved.first.lastIndexOf('/')) : 'Downloads'}.',
        if (uploaded.isNotEmpty) 'Server copy: ${uploaded.length} file(s).',
        ...problems,
      ].join(' ');
}

/// Saves the files to Downloads (Android) and, for a cloud session, uploads a server copy.
Future<ExportOutcome> exportFiles(List<ExportFile> files,
    {required HardwarePlatform platform, V2IRepository? repo, String? sessionId}) async {
  final out = ExportOutcome();
  if (!platform.supportsSavingFiles) out.problems.add('Saving files on this device is not supported (Android only).');
  for (final f in files) {
    if (platform.supportsSavingFiles) {
      try {
        final where = await platform.saveToDownloads(f.name, f.mime, utf8.encode(f.content));
        if (where != null) out.saved.add(where);
      } on PlatformException catch (e) {
        out.problems.add('${f.name}: ${e.message ?? e.code}');
      }
    }
    if (repo != null && sessionId != null) {
      try {
        await repo.uploadExport(sessionId, filename: f.name, contentType: f.mime, content: f.content);
        out.uploaded.add(f.name);
      } on ApiException catch (e) {
        out.problems.add('Server copy of ${f.name}: ${e.message}');
      }
    }
  }
  return out;
}
