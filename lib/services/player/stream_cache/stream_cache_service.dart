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

  /// Keys currently being fetched (teeing to the player, or background fill).
  /// While a key is busy, new requests for it proxy straight through so two
  /// writers never touch the same `.part` file.
  final Set<String> _busyKeys = {};

  /// 0 means unlimited.
  int _maxBytes = 2 * 1024 * 1024 * 1024;

  /// Per-file guard: a single cached song may never exceed this many bytes,
  /// no matter what the server declares or sends. 0 means no guard.
  /// (A 3-minute song is a few MB; 256 MB already covers hour-long mixes.)
  int _maxFileBytes = 256 * 1024 * 1024;

  /// Cache keys of tracks that have actually started playback. Only tees
  /// for these are promoted to cached songs. Tracks that were merely
  /// pre-resolved (next in queue) but never played stay as pending .part
  /// files until another track starts, then are dropped.
  final Set<String> _confirmedIds = <String>{};

  /// Fully-teed .part files waiting for their track to start playing.
  final Map<String, _UpstreamEntry> _pendingParts = <String, _UpstreamEntry>{};

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

  /// Sets the per-file size guard. 0 (or negative) disables the guard.
  void setMaxFileBytes(int bytes) {
    _maxFileBytes = bytes < 0 ? 0 : bytes;
  }

  /// Call when a track actually starts playing. Its pending .part (if the
  /// tee already finished while it was only pre-resolved) gets promoted to
  /// a cached song; pending parts of tracks that never played are dropped.
  void notePlaybackStarted(String trackId) {
    final key = _keyFor(trackId);
    _confirmedIds.add(key);
    // Bound memory: only recent tracks matter.
    if (_confirmedIds.length > 500) {
      _confirmedIds.remove(_confirmedIds.first);
    }
    final pending = _pendingParts.remove(key);
    if (pending != null) {
      unawaited(_promotePending(key, pending));
    }
    // Drop pending parts for other tracks — pre-resolved but never played.
    if (_pendingParts.isNotEmpty) {
      for (final k in _pendingParts.keys.toList()) {
        _pendingParts.remove(k);
        unawaited(_deletePartFile(k));
      }
    }
  }

  Future<void> _promotePending(String key, _UpstreamEntry entry) async {
    try {
      final dir = _dir;
      if (dir == null) return;
      final part = File('${dir.path}/$key.part');
      if (!await part.exists()) return;
      final len = await part.length();
      if (len <= 0) {
        try {
          await part.delete();
        } catch (_) {}
        return;
      }
      await _promotePart(
          key, entry, dir, len, entry.contentType ?? 'audio/mpeg');
      unawaited(_debugLog(
          'PROMOTEPENDING key=$key bytes=$len title="${entry.title}"'));
    } catch (e) {
      log('Pending promote failed for $key: $e', name: 'StreamCache');
    }
  }

  Future<void> _deletePartFile(String key) async {
    try {
      final dir = _dir;
      if (dir == null) return;
      final part = File('${dir.path}/$key.part');
      if (await part.exists()) await part.delete();
      unawaited(_debugLog('PENDINGDROP key=$key'));
    } catch (_) {}
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
    String? quality,
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
      quality: quality,
    );
    return Uri.parse('http://127.0.0.1:${server.port}/c/$key');
  }

  /// Returns a loopback URL for [mediaId] when a COMPLETE cached file is on
  /// disk, without touching the network at all.
  ///
  /// This is the offline-playback path: callers should try this BEFORE asking
  /// a plugin to resolve fresh stream URLs (resolution needs internet for the
  /// InnerTube/cipher handshake). Returns null when the server isn't running
  /// or the track isn't fully cached.
  Future<Uri?> cachedUriFor({required String mediaId}) async {
    final server = _server;
    final dir = _dir;
    if (server == null || dir == null) return null;
    final key = _keyFor(mediaId);
    var complete = false;
    try {
      complete = await File('${dir.path}/$key.bin').exists();
    } catch (_) {
      return null;
    }
    if (!complete) return null;
    _registry[key] = _UpstreamEntry(
      mediaId: mediaId,
      // Fully cached: the file is served from disk, never fetched upstream.
      upstream: null,
      headers: const {},
      title: _index[key]?['title'] as String? ?? mediaId,
      contentType: _index[key]?['contentType'] as String?,
    );
    _touchAccess(key);
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

  /// Per-file cache contents for the in-app diagnostics view (biggest first).
  /// Each entry: title, bytes (actual on-disk size), cachedAt (ISO-8601),
  /// upstream (full source URL, may be '' for entries cached before this
  /// field existed), contentType.
  Future<List<Map<String, dynamic>>> cacheEntries() async {
    final dir = _dir;
    if (dir == null || !await dir.exists()) return [];
    final out = <Map<String, dynamic>>[];
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith('.bin')) {
        final key = fileNameKey(e);
        var bytes = 0;
        try {
          bytes = await e.length();
        } catch (_) {}
        final idx = _index[key];
        out.add({
          'key': key,
          'title': idx?['title'] as String? ?? key,
          'bytes': bytes,
          'cachedAt': idx?['cachedAt'] as String? ?? '',
          'upstream': idx?['upstream'] as String? ?? '',
          'contentType': idx?['contentType'] as String? ?? '',
          'quality': idx?['quality'] as String? ?? '',
        });
      }
    }
    out.sort((a, b) => (b['bytes'] as int).compareTo(a['bytes'] as int));
    return out;
  }

  // ─── Debug log (forensics) ──────────────────────────────────────────
  // Timestamped diagnostics written to cache-debug.log in the cache dir.
  // Answers "how did a 3-minute song become 3 GB": every tee/resume/
  // promote/enforce is logged with byte counts and timings, so a future
  // incident shows whether bytes arrived slowly from the network or
  // appeared instantly (local bug).

  File? get _debugLogFile =>
      _dir == null ? null : File('${_dir!.path}/cache-debug.log');
  static const _maxDebugLogBytes = 200 * 1024;

  /// TEMPORARY (dev only): reads the internal proxy debug log.
  Future<String> readDebugLog() async {
    final f = _debugLogFile;
    if (f == null) return '(log dir not ready)';
    try {
      if (!await f.exists()) return '(log empty)';
      final lines = await f.readAsLines();
      // Show most recent last, cap to last 100 lines for the viewer.
      return lines.length > 100
          ? lines.sublist(lines.length - 100).join('\n')
          : lines.join('\n');
    } catch (e) {
      return '(read failed: $e)';
    }
  }

  Future<void> _debugLog(String msg) async {
    final f = _debugLogFile;
    if (f == null) return;
    try {
      if (await f.exists() && await f.length() > _maxDebugLogBytes) {
        final bytes = await f.readAsBytes();
        await f.writeAsBytes(bytes.sublist(bytes.length ~/ 2), flush: true);
      }
      await f.writeAsString('${DateTime.now().toIso8601String()} $msg\n',
          mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  /// Deletes a single cached song by its cache key. Returns true if something
  /// was deleted.
  Future<bool> deleteEntry(String key) async {
    final dir = _dir;
    if (dir == null) return false;
    var deleted = false;
    final bin = File('${dir.path}/$key.bin');
    final part = File('${dir.path}/$key.part');
    try {
      if (await bin.exists()) {
        await bin.delete();
        deleted = true;
      }
    } catch (_) {}
    try {
      if (await part.exists()) {
        await part.delete();
        deleted = true;
      }
    } catch (_) {}
    if (_index.remove(key) != null) {
      deleted = true;
      await _saveIndex();
    }
    _pendingParts.remove(key);
    _registry.remove(key);
    if (deleted) {
      unawaited(_debugLog('DELETE key=$key'));
    }
    return deleted;
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
    _pendingParts.clear();
    _confirmedIds.clear();
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
        // Stale proxy URL (e.g. after a cache clear wiped the registry).
        unawaited(_debugLog(
            'REQ404 key=$key reason=${entry == null ? 'no-entry' : 'no-dir'}'));
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
    final upstream = entry.upstream;
    if (upstream == null) {
      // Registered as fully cached, but the file vanished (e.g. evicted by
      // the cap) between the lookup and this request.
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }

    // Parse the client's Range header. Players based on ffmpeg/MPV send
    // "Range: bytes=0-" on the very first request; that is semantically a
    // full fetch from byte 0, so we treat it as cacheable. Genuine mid-file
    // ranges (start > 0, e.g. after a seek) proxy straight through.
    final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
    var fromStart = true;
    if (rangeHeader != null) {
      final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
      if (m == null) {
        fromStart = false;
      } else {
        fromStart = int.parse(m.group(1)!) == 0 && m.group(2)!.isEmpty;
      }
    }
    unawaited(_debugLog(
        'REQ key=$key range=${rangeHeader ?? '-'} fromStart=$fromStart'));

    if (_busyKeys.contains(key)) {
      // Another fetch for this track is already writing the cache file.
      await _passthrough(req, entry, upstream);
      return;
    }

    if (!fromStart) {
      await _passthrough(req, entry, upstream);
      return;
    }

    // From-start fetch: pull the whole stream from upstream, pipe it to the
    // player *while* writing it to disk.
    _busyKeys.add(key);
    var completed = false;
    try {
      completed = await _teeFromStart(req, res, key, entry, upstream, dir);
    } finally {
      _busyKeys.remove(key);
    }
    if (!completed) {
      // The player went away early (seek, skip, close). Keep the partial
      // file and fetch the remainder in the background so the song still
      // ends up fully cached.
      _resumeInBackground(key);
    }
  }

  /// Proxies one request straight to upstream without touching the cache.
  Future<void> _passthrough(
      HttpRequest req, _UpstreamEntry entry, Uri upstream) async {
    final res = req.response;
    final range = req.headers.value(HttpHeaders.rangeHeader);
    final clientReq = await _client.getUrl(upstream);
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
    try {
      await res.addStream(upRes);
      await res.close();
    } catch (_) {
      // Player went away; nothing to do.
      try {
        await res.close();
      } catch (_) {}
    }
  }

  /// Fetches the full stream from byte 0, streams it to the player and tees
  /// it into `<key>.part`. Returns true when the whole stream was cached
  /// (file renamed to `<key>.bin`); false when the player disconnected early.
  ///
  /// The client's Range header is intentionally NOT forwarded upstream: a
  /// "bytes=0-" request is answered with a plain 200 + full body, which is
  /// legal HTTP and keeps the on-disk file a plain concatenation of bytes.
  Future<bool> _teeFromStart(HttpRequest req, HttpResponse res, String key,
      _UpstreamEntry entry, Uri upstream, Directory dir) async {
    late final HttpClientResponse upRes;
    try {
      final clientReq = await _client.getUrl(upstream);
      entry.headers.forEach((k, v) {
        try {
          clientReq.headers.set(k, v);
        } catch (_) {}
      });
      upRes = await clientReq.close();
    } catch (e) {
      log('Upstream fetch failed for ${entry.title}: $e', name: 'StreamCache');
      unawaited(_debugLog('UPSTREAMFAIL key=$key title="${entry.title}" error="$e"'));
      res.statusCode = HttpStatus.badGateway;
      try {
        await res.close();
      } catch (_) {}
      return false;
    }

    // Never cache encoded (e.g. gzipped) bodies — the on-disk file must be
    // plain audio bytes.
    final plain = upRes.headers.value(HttpHeaders.contentEncodingHeader) == null;
    if (upRes.statusCode != HttpStatus.ok || !plain) {
      // Error or encoded: stream straight through uncached.
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
      try {
        await res.addStream(upRes);
        await res.close();
      } catch (_) {
        try {
          await res.close();
        } catch (_) {}
      }
      return false;
    }

    final contentType = upRes.headers.contentType?.mimeType;
    res.statusCode = HttpStatus.ok;
    res.headers.set(HttpHeaders.contentTypeHeader,
        contentType ?? entry.contentType ?? 'audio/mpeg');
    res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    final upstreamLength = upRes.contentLength;
    if (upstreamLength >= 0) res.contentLength = upstreamLength;

    final tmp = File('${dir.path}/$key.part');
    IOSink? sink;
    try {
      // Start fresh; a stale partial from an older session is dropped here
      // (a resume only continues a partial from THIS session, see below).
      if (await tmp.exists()) await tmp.delete();
      sink = tmp.openWrite();
    } catch (_) {
      sink = null;
    }
    final teeWatch = Stopwatch()..start();
    unawaited(_debugLog('TEESTART key=$key title="${entry.title}" '
        'host=${upstream.host} declaredLen=$upstreamLength '
        'playerRange=${req.headers.value(HttpHeaders.rangeHeader) ?? '-'}'));
    var bytes = 0;
    var guardTripped = false;
    try {
      await for (final chunk in upRes) {
        bytes += chunk.length;
        res.add(chunk);
        // Per-file guard: never trust the server's declared size — enforce
        // our own cap on the ACTUAL bytes written. If tripped, stop writing
        // to disk (delete the partial) but keep serving the player, so
        // playback is unaffected; the song just won't be cached.
        if (!guardTripped &&
            _maxFileBytes > 0 &&
            bytes > _maxFileBytes) {
          guardTripped = true;
          try {
            await sink?.close();
          } catch (_) {}
          sink = null;
          try {
            if (await tmp.exists()) await tmp.delete();
          } catch (_) {}
          unawaited(_debugLog('GUARDTRIPPED key=$key bytes=$bytes '
              'cap=$_maxFileBytes title="${entry.title}"'));
          log('Cache guard tripped for "${entry.title}" at ${_fmtBytes(bytes)} '
              '(cap ${_fmtBytes(_maxFileBytes)}) — serving uncached',
              name: 'StreamCache');
        }
        if (!guardTripped) sink?.add(chunk);
      }
      try {
        await res.close();
      } catch (_) {}
      try {
        await sink?.flush();
        await sink?.close();
      } catch (_) {}
      if (bytes > 0 && !guardTripped) {
        if (_confirmedIds.contains(key)) {
          await _promotePart(key, entry, dir, bytes,
              contentType ?? entry.contentType ?? 'audio/mpeg');
          unawaited(_debugLog('TEEEND key=$key bytes=$bytes '
              'declared=$upstreamLength elapsedMs=${teeWatch.elapsedMilliseconds} '
              'result=promoted'));
        } else {
          // Tee finished but the track never started playing (it was only
          // pre-resolved as "next"). Hold the .part: it promotes when
          // notePlaybackStarted arrives, or is dropped when another track
          // starts.
          entry.contentType = contentType ?? entry.contentType;
          _pendingParts[key] = entry;
          unawaited(_debugLog('TEEEND key=$key bytes=$bytes '
              'declared=$upstreamLength elapsedMs=${teeWatch.elapsedMilliseconds} '
              'result=pending-playback'));
        }
        return true;
      }
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      unawaited(_debugLog('TEEEND key=$key bytes=$bytes '
          'declared=$upstreamLength elapsedMs=${teeWatch.elapsedMilliseconds} '
          'result=${guardTripped ? 'guard-tripped' : 'empty'}'));
      return false;
    } catch (e) {
      // Player went away mid-stream: keep the partial file; the remainder
      // is fetched in the background by [_resumeInBackground].
      try {
        await sink?.close();
      } catch (_) {}
      try {
        await res.close();
      } catch (_) {}
      unawaited(_debugLog('TEEEND key=$key bytes=$bytes '
          'declared=$upstreamLength elapsedMs=${teeWatch.elapsedMilliseconds} '
          'result=interrupted err=$e'));
      log('Tee interrupted for "${entry.title}" after ${_fmtBytes(bytes)}'
          ' — will resume in background',
          name: 'StreamCache');
      return false;
    }
  }

  /// Moves `<key>.part` to `<key>.bin` and records it in the index.
  Future<void> _promotePart(String key, _UpstreamEntry entry, Directory dir,
      int bytes, String contentType) async {
    final tmp = File('${dir.path}/$key.part');
    final done = File('${dir.path}/$key.bin');
    try {
      if (await done.exists()) await done.delete();
      await tmp.rename(done.path);
      final now = DateTime.now().toIso8601String();
      _index[key] = {
        'mediaId': entry.mediaId,
        'title': entry.title,
        'contentType': contentType,
        'bytes': bytes,
        'cachedAt': now,
        'lastAccess': now,
        // Full upstream URL for forensics (e.g. why a "song" is gigabytes).
        // Stays on-device in index.json; tokens inside expire anyway.
        'upstream': entry.upstream?.toString() ?? '',
        'quality': entry.quality ?? '',
      };
      await _saveIndex();
      await _enforceCap();
      final upHost = entry.upstream?.host ?? '?';
      unawaited(_debugLog('PROMOTE key=$key bytes=$bytes title="${entry.title}"'));
      log('Cached "${entry.title}" (${_fmtBytes(bytes)}) from $upHost',
          name: 'StreamCache');
    } catch (e) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  /// Kicks off a background fetch that appends the missing tail of `<key>.part`
  /// (from a tee interrupted by a seek/skip) and promotes it to `<key>.bin`.
  void _resumeInBackground(String key) {
    if (_busyKeys.contains(key)) return;
    final entry = _registry[key];
    final dir = _dir;
    final upstream = entry?.upstream;
    if (entry == null || dir == null || upstream == null) return;
    _busyKeys.add(key);
    unawaited(_doResume(key, entry, upstream, dir)
        .whenComplete(() => _busyKeys.remove(key)));
  }

  Future<void> _doResume(String key, _UpstreamEntry entry, Uri upstream,
      Directory dir) async {
    final part = File('${dir.path}/$key.part');
    var have = 0;
    try {
      if (!await part.exists()) return;
      have = await part.length();
    } catch (_) {
      return;
    }
    if (have <= 0) return;
    unawaited(
        _debugLog('RESUMESTART key=$key have=$have title="${entry.title}"'));
    try {
      final clientReq = await _client.getUrl(upstream);
      entry.headers.forEach((k, v) {
        try {
          clientReq.headers.set(k, v);
        } catch (_) {}
      });
      clientReq.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
      final upRes = await clientReq.close();
      if (upRes.statusCode != HttpStatus.partialContent) {
        // Can't resume (expired URL, server refused Range, ...): drop the
        // partial; the next play retries from scratch.
        unawaited(_debugLog(
            'RESUMEEND key=$key have=$have status=${upRes.statusCode} result=dropped'));
        try {
          await part.delete();
        } catch (_) {}
        return;
      }
      final sink = part.openWrite(mode: FileMode.append);
      var bytes = have;
      try {
        await for (final chunk in upRes) {
          bytes += chunk.length;
          if (_maxFileBytes > 0 && bytes > _maxFileBytes) {
            // Per-file guard tripped during resume: give up, delete partial.
            try {
              await sink.close();
            } catch (_) {}
            try {
              if (await part.exists()) await part.delete();
            } catch (_) {}
            unawaited(_debugLog('GUARDTRIPPED key=$key bytes=$bytes '
                'cap=$_maxFileBytes title="${entry.title}" (resume)'));
            log('Cache guard tripped for "${entry.title}" during resume at '
                '${_fmtBytes(bytes)} — partial deleted',
                name: 'StreamCache');
            return;
          }
          sink.add(chunk);
        }
        await sink.flush();
        await sink.close();
      } catch (_) {
        try {
          await sink.close();
        } catch (_) {}
        return; // keep partial for a later attempt
      }
      final contentType = upRes.headers.contentType?.mimeType ??
          entry.contentType ??
          'audio/mpeg';
      if (_confirmedIds.contains(key)) {
        await _promotePart(key, entry, dir, bytes, contentType);
        unawaited(_debugLog(
            'RESUMEEND key=$key have=$have bytes=$bytes status=206 result=promoted'));
        log('Resumed + cached "${entry.title}" (${_fmtBytes(bytes)})',
            name: 'StreamCache');
      } else {
        // Resume finished but the track never started playing — hold as
        // pending, same as the from-start path.
        entry.contentType = contentType;
        _pendingParts[key] = entry;
        unawaited(_debugLog(
            'RESUMEEND key=$key have=$have bytes=$bytes status=206 result=pending-playback'));
      }
    } catch (_) {
      // Network hiccup: leave the .part for a later attempt.
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
    final totalBefore = total;
    var evicted = 0;
    for (final s in sized) {
      if (total <= _maxBytes) break;
      try {
        await s.file.delete();
        total -= s.bytes;
        _index.remove(s.key);
        evicted++;
        log('Evicted cached "${_index[s.key]?['title'] ?? s.key}" to stay under cap',
            name: 'StreamCache');
      } catch (_) {}
    }
    await _saveIndex();
    unawaited(_debugLog('ENFORCE before=$totalBefore after=$total '
        'evicted=$evicted cap=$_maxBytes'));
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
    const units = ['B', 'KB', 'MB', 'GB'];
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
  /// Null when the track is fully cached — the file is served from disk and
  /// never fetched upstream.
  final Uri? upstream;
  final Map<String, String> headers;
  final String title;
  String? contentType;
  final String? quality;

  _UpstreamEntry({
    required this.mediaId,
    required this.upstream,
    required this.headers,
    required this.title,
    this.contentType,
    this.quality,
  });
}
