import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';

/// Transparent on-disk cache for streamed audio.
///
/// How it works:
/// - A tiny HTTP server binds to 127.0.0.1 on an ephemeral port at app start.
/// - [MediaResolverService] asks [proxyUriFor] for a loopback URL per track and
///   hands that URL to the player instead of the (expiring) upstream URL.
/// - First play of a song: the server fetches the upstream stream, pipes it to
///   the player *while* writing it to disk. Only bytes the player actually
///   requests are stored, so skipping a song early does not download the rest.
/// - Later plays: the complete file is served straight from disk (with HTTP
///   Range support, so seeking works) — zero network, works offline.
///
/// Cache keys are derived from the stable track media ID, *not* the upstream
/// URL, because plugin stream URLs are signed and expire.
///
/// Size is bounded by [maxBytes] (0 = unlimited) using LRU eviction driven by
/// the `lastAccess` timestamps kept in `index.json`.
class StreamCacheService {
  StreamCacheService._();
  static final StreamCacheService instance = StreamCacheService._();

  HttpServer? _server;
  Directory? _dir;
  File? _indexFile;

  /// mediaId-key -> upstream location + headers for the current session.
  final Map<String, _UpstreamEntry> _registry = {};

  /// key -> {mediaId, title, contentType, bytes, cachedAt, lastAccess}.
  Map<String, Map<String, dynamic>> _index = {};

  final HttpClient _client = HttpClient()..autoUncompress = false;
  bool _starting = false;

  /// 0 means unlimited.
  int _maxBytes = 2 * 1024 * 1024 * 1024;

  bool get isRunning => _server != null;
  int get port => _server?.port ?? -1;

  /// Parses a cap stored as megabytes in a string (e.g. "2048").
  /// Returns bytes; "0"/unparsable-with-default -> [defaultMb].
  static int mbStringToBytes(String? value, {int defaultMb = 2048}) {
    final mb = int.tryParse((value ?? '').trim());
    if (mb == null) return defaultMb * 1024 * 1024;
    if (mb <= 0) return 0; // 0 (or negative) = unlimited
    return mb * 1024 * 1024;
  }

  void setMaxBytes(int bytes) {
    _maxBytes = bytes < 0 ? 0 : bytes;
    // Enforce lazily — never block the UI thread on I/O here.
    unawaited(_enforceCap().catchError((_) {}));
  }

  Future<void> start({required String cacheDir}) async {
    if (isRunning || _starting) return;
    _starting = true;
    try {
      _dir = Directory(cacheDir);
      await _dir!.create(recursive: true);
      _indexFile = File('${_dir!.path}/index.json');
      await _loadIndex();
      // Drop interrupted partial downloads left by a previous run.
      await for (final e in _dir!.list()) {
        if (e is File && e.path.endsWith('.part')) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server!.listen(_handleRequest);
      log('Stream cache on 127.0.0.1:${_server!.port} dir=$cacheDir',
          name: 'StreamCache');
      await _enforceCap();
    } finally {
      _starting = false;
    }
  }

  Future<void> dispose() async {
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
    _client.close(force: true);
  }

  /// Returns a loopback URL the player can open for [mediaId], or null when
  /// the cache server is not running (caller should fall back to [upstream]).
  Uri? proxyUriFor({
    required String mediaId,
    required Uri upstream,
    Map<String, String>? headers,
    String? title,
    String? contentType,
  }) {
    final server = _server;
    if (server == null) return null;
    final key = _keyFor(mediaId);
    _registry[key] = _UpstreamEntry(
      mediaId: mediaId,
      upstream: upstream,
      headers: headers ?? const {},
      title: (title?.isNotEmpty ?? false) ? title! : mediaId,
      contentType: contentType,
    );
    return Uri.parse('http://127.0.0.1:${server.port}/c/$key');
  }

  /// Total cached songs and bytes on disk.
  Future<({int files, int bytes})> usage() async {
    final dir = _dir;
    if (dir == null || !await dir.exists()) return (files: 0, bytes: 0);
    var files = 0;
    var bytes = 0;
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith('.bin')) {
        files++;
        try {
          bytes += await e.length();
        } catch (_) {}
      }
    }
    return (files: files, bytes: bytes);
  }

  /// Deletes every cached song. Registrations are kept — the next play of a
  /// cleared song simply re-fetches it from upstream.
  Future<void> clear() async {
    final dir = _dir;
    if (dir == null) return;
    await for (final e in dir.list()) {
      if (e is File &&
          (e.path.endsWith('.bin') || e.path.endsWith('.part'))) {
        try {
          await e.delete();
        } catch (_) {}
      }
    }
    _index.clear();
    await _saveIndex();
    log('Stream cache cleared', name: 'StreamCache');
  }

  // ─── HTTP handling ──────────────────────────────────────────────────────

  Future<void> _handleRequest(HttpRequest req) async {
    try {
      if (req.method != 'GET') {
        req.response
          ..statusCode = HttpStatus.methodNotAllowed
          ..close();
        return;
      }
      final segs = req.uri.pathSegments;
      if (segs.length != 2 || segs[0] != 'c') {
        req.response
          ..statusCode = HttpStatus.notFound
          ..close();
        return;
      }
      final key = segs[1];
      final entry = _registry[key];
      final dir = _dir;
      if (entry == null || dir == null) {
        req.response
          ..statusCode = HttpStatus.notFound
          ..close();
        return;
      }
      final complete = File('${dir.path}/$key.bin');
      if (await complete.exists()) {
        _touchAccess(key);
        await _serveFile(req, complete, entry);
      } else {
        await _proxyUpstream(req, key, entry);
      }
    } catch (e) {
      log('Cache request failed: $e', name: 'StreamCache');
      try {
        req.response
          ..statusCode = HttpStatus.internalServerError
          ..close();
      } catch (_) {}
    }
  }

  Future<void> _serveFile(
      HttpRequest req, File file, _UpstreamEntry entry) async {
    final length = await file.length();
    final res = req.response;
    final contentType =
        entry.contentType ?? _index[fileNameKey(file)]?['contentType'] as String? ?? 'audio/mpeg';

    // Parse "Range: bytes=start-end".
    var start = 0;
    var end = length - 1;
    var partial = false;
    final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
    if (rangeHeader != null) {
      final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
      if (m != null) {
        final s = int.parse(m.group(1)!);
        if (s < length) {
          start = s;
          final eStr = m.group(2)!;
          end = eStr.isEmpty ? length - 1 : int.parse(eStr);
          if (end >= length) end = length - 1;
          partial = start != 0 || end != length - 1;
        }
      }
    }

    res.headers.set(HttpHeaders.contentTypeHeader, contentType);
    res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (partial) {
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(
          HttpHeaders.contentRangeHeader, 'bytes $start-$end/$length');
      res.contentLength = end - start + 1;
    } else {
      res.statusCode = HttpStatus.ok;
      res.contentLength = length;
    }
    await res.addStream(file.openRead(start, end + 1));
    await res.close();
  }

  Future<void> _proxyUpstream(
      HttpRequest req, String key, _UpstreamEntry entry) async {
    final dir = _dir!;
    final res = req.response;
    final range = req.headers.value(HttpHeaders.rangeHeader);
    // Only cache full, non-ranged responses fetched from byte 0.
    final cacheable = range == null;

    final clientReq = await _client.getUrl(entry.upstream);
    entry.headers.forEach((k, v) {
      try {
        clientReq.headers.set(k, v);
      } catch (_) {}
    });
    if (range != null) clientReq.headers.set(HttpHeaders.rangeHeader, range);

    late final HttpClientResponse upRes;
    try {
      upRes = await clientReq.close();
    } catch (e) {
      log('Upstream fetch failed for ${entry.title}: $e', name: 'StreamCache');
      res.statusCode = HttpStatus.badGateway;
      await res.close();
      return;
    }

    res.statusCode = upRes.statusCode;
    for (final h in [
      HttpHeaders.contentTypeHeader,
      HttpHeaders.contentLengthHeader,
      HttpHeaders.acceptRangesHeader,
      HttpHeaders.contentRangeHeader,
      HttpHeaders.contentEncodingHeader,
    ]) {
      final v = upRes.headers.value(h);
      if (v != null) res.headers.set(h, v);
    }
    final contentType = upRes.headers.contentType?.mimeType;

    // Never cache encoded (e.g. gzipped) bodies — the on-disk file must be
    // plain audio bytes so it can be served back with a plain content-type.
    final cacheableNow =
        cacheable && upRes.headers.value(HttpHeaders.contentEncodingHeader) == null;

    if (upRes.statusCode != HttpStatus.ok || !cacheableNow) {
      // Ranged/partial, encoded, or error responses stream straight through
      // uncached.
      await res.addStream(upRes);
      await res.close();
      return;
    }

    final tmp = File('${dir.path}/$key.part');
    IOSink? sink;
    try {
      sink = tmp.openWrite();
    } catch (_) {
      sink = null;
    }
    var bytes = 0;
    try {
      await for (final chunk in upRes) {
        bytes += chunk.length;
        res.add(chunk);
        sink?.add(chunk);
      }
      await res.close();
      try {
        await sink?.flush();
        await sink?.close();
      } catch (_) {}
      if (bytes > 0) {
        final done = File('${dir.path}/$key.bin');
        try {
          if (await done.exists()) await done.delete();
          await tmp.rename(done.path);
          final now = DateTime.now().toIso8601String();
          _index[key] = {
            'mediaId': entry.mediaId,
            'title': entry.title,
            'contentType': contentType ?? entry.contentType ?? 'audio/mpeg',
            'bytes': bytes,
            'cachedAt': now,
            'lastAccess': now,
          };
          await _saveIndex();
          await _enforceCap();
          log('Cached "${entry.title}" (${_fmtBytes(bytes)})',
              name: 'StreamCache');
        } catch (e) {
          try {
            if (await tmp.exists()) await tmp.delete();
          } catch (_) {}
        }
      } else {
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
      }
    } catch (e) {
      // Player went away mid-stream — drop the partial file.
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      try {
        await res.close();
      } catch (_) {}
    }
  }

  // ─── Cap enforcement (LRU) ──────────────────────────────────────────────

  Future<void> _enforceCap() async {
    if (_maxBytes <= 0) return; // unlimited
    final dir = _dir;
    if (dir == null || !await dir.exists()) return;
    final bins = <File>[];
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith('.bin')) bins.add(e);
    }
    var total = 0;
    final sized = <({File file, int bytes, String key, String lastAccess})>[];
    for (final f in bins) {
      int b = 0;
      try {
        b = await f.length();
      } catch (_) {
        continue;
      }
      total += b;
      final key = fileNameKey(f);
      sized.add((
        file: f,
        bytes: b,
        key: key,
        lastAccess: _index[key]?['lastAccess'] as String? ?? '',
      ));
    }
    if (total <= _maxBytes) return;
    // Oldest access first.
    sized.sort((a, b) => a.lastAccess.compareTo(b.lastAccess));
    for (final s in sized) {
      if (total <= _maxBytes) break;
      try {
        await s.file.delete();
        total -= s.bytes;
        _index.remove(s.key);
        log('Evicted cached "${_index[s.key]?['title'] ?? s.key}" to stay under cap',
            name: 'StreamCache');
      } catch (_) {}
    }
    await _saveIndex();
  }

  void _touchAccess(String key) {
    final e = _index[key];
    if (e == null) return;
    e['lastAccess'] = DateTime.now().toIso8601String();
    // Persist lazily; a crash only loses recency info.
    unawaited(_saveIndex().catchError((_) {}));
  }

  // ─── Index persistence ──────────────────────────────────────────────────

  Future<void> _loadIndex() async {
    final f = _indexFile;
    if (f == null || !await f.exists()) return;
    try {
      final raw = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      _index = raw.map((k, v) =>
          MapEntry(k, Map<String, dynamic>.from(v as Map<String, dynamic>)));
    } catch (_) {
      _index = {};
    }
  }

  Future<void> _saveIndex() async {
    final f = _indexFile;
    if (f == null) return;
    try {
      await f.writeAsString(jsonEncode(_index), flush: true);
    } catch (_) {}
  }

  // ─── Helpers ────────────────────────────────────────────────────────────

  String _keyFor(String mediaId) {
    var k = mediaId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    if (k.length > 80) k = k.substring(0, 80);
    return k.isEmpty ? 'track' : k;
  }

  String fileNameKey(File f) {
    final name = f.path.split(Platform.pathSeparator).last;
    return name.replaceAll(RegExp(r'\.(bin|part)$'), '');
  }

  static String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB'];
    var v = bytes.toDouble();
    var u = 0;
    while (v >= 1024 && u < units.length - 1) {
      v /= 1024;
      u++;
    }
    return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[u]}';
  }
}

class _UpstreamEntry {
  final String mediaId;
  final Uri upstream;
  final Map<String, String> headers;
  final String title;
  String? contentType;

  _UpstreamEntry({
    required this.mediaId,
    required this.upstream,
    required this.headers,
    required this.title,
    this.contentType,
  });
}
