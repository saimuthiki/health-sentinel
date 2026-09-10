/// What the connection to the backend is doing, for the one part of the
/// interface that has to say so out loud.
///
/// The health engine runs on Render's free tier. Free instances are stopped
/// after a quarter of an hour without traffic and are started again by the first
/// request that arrives, which takes somewhere around fifty seconds — a whole
/// minute of a spinner that looks exactly like a broken app. Naming it is the
/// difference between "this is slow today" and "this is broken".
enum ApiPhase {
  /// Nothing in flight.
  idle,

  /// A request is in flight and the backend is believed to be awake.
  working,

  /// A request is in flight, the backend was asleep, and it is starting up.
  /// This is the state the "waking up the health engine" copy hangs off.
  waking,

  /// The last request succeeded.
  ready,

  /// The last request could not reach the backend at all.
  unreachable,
}

extension ApiPhaseCopy on ApiPhase {
  /// The line shown while waiting. Written once, here, so Today and Plan and
  /// Reports never drift into three different explanations of the same wait.
  String get waitingMessage {
    switch (this) {
      case ApiPhase.waking:
        return 'Waking up the health engine';
      case ApiPhase.idle:
      case ApiPhase.working:
      case ApiPhase.ready:
      case ApiPhase.unreachable:
        return 'Getting your day ready';
    }
  }

  String? get waitingDetail {
    switch (this) {
      case ApiPhase.waking:
        return 'It runs on free hosting and sleeps when nobody is using it, so '
            'the first request of the day can take up to a minute. Nothing is '
            'wrong - please stay on this screen.';
      case ApiPhase.idle:
      case ApiPhase.working:
      case ApiPhase.ready:
      case ApiPhase.unreachable:
        return null;
    }
  }
}
