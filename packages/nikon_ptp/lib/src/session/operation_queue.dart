import 'dart:async';

import '../errors/ptp_errors.dart';
import '../transport/cancel_token.dart';

/// Priority tier for queued PTP operations.
///
/// PTP is strictly serial (one command at a time) so ordering matters.
/// Live View frames run at [low], cancels/keepalives at [critical], and
/// user-initiated actions at [high] so a tap-to-focus can preempt the
/// LV frame stream.
enum OpPriority { critical, high, normal, low, background }

typedef OperationRunner<T> = Future<T> Function();

/// Type-erased operation record. The runner is `Future<Object?> Function()`
/// so the queue can hold heterogeneous operations without generic gymnastics;
/// [submit] wraps the caller's [OperationRunner]<T> in a shim and pipes the
/// result back through a typed [Completer]<T>.
final class _Operation {
  _Operation({
    required this.priority,
    required this.seq,
    required this.run,
    required this.cancelToken,
  });

  final OpPriority priority;
  final int seq;
  final Future<void> Function() run;
  final CancelToken? cancelToken;
}

/// Single-worker priority queue that serialises transport access.
///
/// One instance per [Transport]. A caller submits via [submit] and
/// receives a future that completes when the runner finishes.
final class OperationQueue {
  OperationQueue({this.name = 'op-queue'});

  final String name;

  final _HeapPriorityQueue _pending = _HeapPriorityQueue();
  int _seq = 0;
  bool _running = false;
  bool _closed = false;

  Future<T> submit<T>(
    OperationRunner<T> runner, {
    OpPriority priority = OpPriority.normal,
    CancelToken? cancelToken,
  }) {
    if (_closed) {
      return Future<T>.error(
        const PtpTransportException('operation queue closed'),
      );
    }
    final completer = Completer<T>();
    final op = _Operation(
      priority: priority,
      seq: _seq++,
      cancelToken: cancelToken,
      run: () async {
        if (cancelToken?.isCancelled ?? false) {
          completer.completeError(const PtpCancelledException());
          return;
        }
        try {
          final result = await runner();
          if (!completer.isCompleted) completer.complete(result);
        } catch (e, st) {
          if (!completer.isCompleted) completer.completeError(e, st);
        }
      },
    );
    _pending.add(op);
    _pump();
    return completer.future;
  }

  Future<void> close({Object? cause}) async {
    if (_closed) return;
    _closed = true;
    // Best-effort: pending ops just get their runner invoked, which will
    // see cancelToken/error paths and complete normally.
    for (final op in _pending.drainAll()) {
      unawaited(op.run());
    }
  }

  void _pump() {
    if (_running || _closed) return;
    if (_pending.isEmpty) return;
    _running = true;
    scheduleMicrotask(_runNext);
  }

  Future<void> _runNext() async {
    while (!_closed && _pending.isNotEmpty) {
      final op = _pending.removeFirst();
      try {
        await op.run();
      } catch (_) {
        // Runner already forwards to its completer; swallow secondaries.
      }
    }
    _running = false;
  }
}

/// Minimal binary-heap priority queue tuned for our workload (~10s of items).
/// Kept in-package so `package:collection` isn't a hard dependency here.
final class _HeapPriorityQueue {
  final List<_Operation> _items = [];

  bool get isEmpty => _items.isEmpty;
  bool get isNotEmpty => _items.isNotEmpty;
  int get length => _items.length;

  void add(_Operation item) {
    _items.add(item);
    _bubbleUp(_items.length - 1);
  }

  _Operation removeFirst() {
    if (_items.isEmpty) {
      throw StateError('queue empty');
    }
    final root = _items.first;
    final last = _items.removeLast();
    if (_items.isNotEmpty) {
      _items[0] = last;
      _bubbleDown(0);
    }
    return root;
  }

  Iterable<_Operation> drainAll() {
    final drained = List<_Operation>.from(_items);
    _items.clear();
    return drained;
  }

  int _compare(_Operation a, _Operation b) {
    final byPriority = a.priority.index - b.priority.index;
    if (byPriority != 0) return byPriority;
    return a.seq - b.seq;
  }

  void _bubbleUp(int index) {
    while (index > 0) {
      final parent = (index - 1) >> 1;
      if (_compare(_items[index], _items[parent]) < 0) {
        final tmp = _items[index];
        _items[index] = _items[parent];
        _items[parent] = tmp;
        index = parent;
      } else {
        break;
      }
    }
  }

  void _bubbleDown(int index) {
    final n = _items.length;
    while (true) {
      final left = (index << 1) + 1;
      final right = left + 1;
      var smallest = index;
      if (left < n && _compare(_items[left], _items[smallest]) < 0) {
        smallest = left;
      }
      if (right < n && _compare(_items[right], _items[smallest]) < 0) {
        smallest = right;
      }
      if (smallest == index) return;
      final tmp = _items[index];
      _items[index] = _items[smallest];
      _items[smallest] = tmp;
      index = smallest;
    }
  }
}
