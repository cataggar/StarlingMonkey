// Shared fixture used by run-runtime-tests.sh across every feature
// combination. Registers a single fetch handler (unless fetch-event is
// disabled, in which case the registration itself throws and is caught)
// that exercises random/clocks/http behavior and reports results in the
// HTTP response body -- deliberately not relying on console.log/stderr,
// since stdio is itself one of the features under test and may be
// disabled.
function handler(event) {
  event.respondWith((async () => {
    const results = [];

    try {
      const bytes = new Uint8Array(4);
      crypto.getRandomValues(bytes);
      results.push('random:ok:' + Array.from(bytes).join(','));
    } catch (e) {
      results.push('random:caught:' + e.message);
    }

    try {
      await new Promise((resolve) => setTimeout(resolve, 0));
      results.push('clocks:ok');
    } catch (e) {
      results.push('clocks:caught:' + e.message);
    }

    try {
      AbortSignal.timeout(0);
      results.push('abort-timeout:ok');
    } catch (e) {
      results.push('abort-timeout:caught:' + e.message);
    }

    try {
      await fetch('http://example.invalid/');
      results.push('http:ok');
    } catch (e) {
      results.push('http:caught:' + e.message);
    }

    return new Response(results.join('|'));
  })());
}

try {
  addEventListener('fetch', handler);
} catch (e) {
  // fetch-event is disabled: no working handler is registered. Callers
  // that build with fetch-event disabled must not expect this component to
  // serve a normal 200 response -- see run-runtime-tests.sh's
  // "no-handler-registered" assertions (a live request must still fail
  // deterministically via the pre-existing REQUEST_HANDLER_ONLY guard in
  // host_api.cpp, not hang or corrupt state).
}
