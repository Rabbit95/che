/// PTP-IP replay server.
///
/// Loads a recorded byte trace and serves it on port 15740 so the app
/// (or an integration test) can connect without a real camera present.
///
/// Trace format is a JSON manifest listing `<direction>|<hex-bytes>` frames
/// in wire-order; a small extractor script (tools/pcap2fixtures) will
/// consume `tshark` output. Kept as a scaffold for now — the actual
/// replay engine lands with the M1 CI wiring.
///
/// Usage:
///   dart run tools/ptp_replay_server/bin/replay.dart --trace fixtures/z8_v3.json
///
/// TODO(M1-CI): implement trace loader + per-frame direction check.
library;

import 'dart:io';

Future<void> main(List<String> args) async {
  stderr.writeln('ptp_replay_server scaffold — not yet functional.');
  stderr.writeln('See PLAN.md §测试策略 for the intended shape.');
  exit(64);
}
