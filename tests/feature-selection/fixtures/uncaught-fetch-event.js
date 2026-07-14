// Deliberately does NOT catch the FeatureDisabled exception thrown by
// addEventListener('fetch', ...) when fetch-event is disabled, so that
// StarlingMonkey's own top-level-script-exception reporter prints the
// exact diagnostic message to stderr during componentize.sh -- used by
// run-runtime-tests.sh to assert on the precise message text. Only valid
// for combinations where stdio remains enabled (otherwise the message is
// silently discarded by design; see docs/feature-selection/README.md).
addEventListener('fetch', (event) => { event.respondWith(new Response('should-not-run')); });
