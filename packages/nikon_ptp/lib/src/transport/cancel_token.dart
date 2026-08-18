import 'dart:async';

import '../errors/ptp_errors.dart';

/// Cooperative cancellation signal handed to long-running operations
/// (multi-chunk downloads, Live View loops, etc).
///
/// Callers check [isCancelled] between chunks and throw
/// [PtpCancelledException] if it flips true. [whenCancelled] lets you
/// await a cancellation as a future.
final class CancelToken {
  CancelToken();

  final Completer<void> _done = Completer<void>();
  bool _cancelled = false;

  bool get isCancelled => _cancelled;
  Future<void> get whenCancelled => _done.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    if (!_done.isCompleted) _done.complete();
  }

  void throwIfCancelled() {
    if (_cancelled) throw const PtpCancelledException();
  }
}
