import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'decide.dart';

/// Append-only audit log. Every decision — including the rejected ones — lands here.
///
/// "Why did it NOT switch" matters as much as "why did it switch"; without the
/// rejections the scheduler stays a black box.
class AuditLog {
  final File file;
  IOSink? _sink;

  AuditLog(String path) : file = File(path);

  Future<void> open() async {
    await file.parent.create(recursive: true);
    _sink = file.openWrite(mode: FileMode.append);
  }

  void write(Decision d) {
    _sink?.writeln(jsonEncode(d.toJson()));
  }

  Future<void> close() async {
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
  }
}
