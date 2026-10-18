import 'package:Bloomee/services/player/stream_quality_selector.dart';
import 'package:Bloomee/src/rust/api/plugin/models.dart';

/// TEMPORARY diagnostic (dev branch only): records what the YT Music plugin
/// returns for a song and which stream each quality preference would pick.
/// Read-only: never changes what gets played or cached.
class StreamQualityDiagnostic {
  StreamQualityDiagnostic._();

  static String? lastReport;

  static void record({
    required String trackTitle,
    required List<StreamSource> streams,
    required bool audioOnly,
    required AudioStreamQualityPreference userPreference,
    required StreamSource? userSelected,
  }) {
    final buf = StringBuffer();
    buf.writeln('Song: $trackTitle');
    buf.writeln('audioOnly filter: $audioOnly');
    buf.writeln('Plugin returned ${streams.length} stream(s):');
    for (var i = 0; i < streams.length; i++) {
      final s = streams[i];
      final uri = Uri.tryParse(s.url);
      final itag = uri?.queryParameters['itag'] ?? '-';
      buf.writeln(
          '  [$i] quality=${s.quality.name} format=${s.format} itag=$itag host=${uri?.host}');
    }
    buf.writeln('Picks per preference:');
    for (final pref in AudioStreamQualityPreference.values) {
      final pick = StreamQualitySelector.selectPlaybackStream(
        streams,
        preference: pref,
        audioOnly: audioOnly,
      );
      final idx = pick == null ? -1 : streams.indexOf(pick);
      final marker = pref == userPreference ? '  <-- your setting' : '';
      buf.writeln('  ${pref.name}: stream [$idx]$marker');
    }
    final userIdx =
        userSelected == null ? -1 : streams.indexOf(userSelected);
    buf.writeln('Actually played/cached: stream [$userIdx] '
        '(preference=${userPreference.name})');
    lastReport = buf.toString();
  }
}
