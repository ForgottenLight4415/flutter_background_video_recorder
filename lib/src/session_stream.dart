import 'dart:async';

/// The stream of a raw capture session: any number of listeners share it.
///
/// It listens to the platform stream while at least one listener is attached (so the native side
/// can skip the work of preparing data nobody reads), forwards data and errors, and completes when
/// the session is closed or the platform stream ends.
class SessionStream<T> {
  /// Forwards [source] to listeners. [closeSession] ends the session on the native side.
  ///
  /// Items are delivered to all listeners synchronously, and [onDispatched] runs right after, so
  /// something that listeners may only use during delivery (a frame in native memory) can be given
  /// back as soon as they have all returned.
  SessionStream(
    this._source,
    this._closeSession, {
    void Function(T item)? onDispatched,
  }) : _onDispatched = onDispatched {
    _controller = StreamController<T>.broadcast(
      sync: true,
      onListen: _attach,
      onCancel: _detach,
    );
  }

  final Stream<T> _source;
  final Future<void> Function() _closeSession;
  final void Function(T item)? _onDispatched;
  late final StreamController<T> _controller;
  StreamSubscription<T>? _upstream;
  Future<void>? _closing;

  /// The data of the session. A broadcast stream: listen as often as you like.
  Stream<T> get stream => _controller.stream;

  void _attach() {
    if (_controller.isClosed) return;
    _upstream ??= _source.listen(
      _deliver,
      onError: _controller.addError,
      onDone: _finish,
    );
  }

  void _deliver(T item) {
    try {
      if (!_controller.isClosed) _controller.add(item);
    } finally {
      _onDispatched?.call(item);
    }
  }

  Future<void> _detach() async {
    final upstream = _upstream;
    _upstream = null;
    await upstream?.cancel();
  }

  Future<void> _finish() async {
    _upstream = null;
    if (!_controller.isClosed) await _controller.close();
  }

  /// Ends the session. Safe to call more than once.
  Future<void> close() => _closing ??= _doClose();

  Future<void> _doClose() async {
    try {
      await _closeSession();
    } finally {
      await _detach();
      await _finish();
    }
  }
}
