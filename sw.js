/* Cache first for the app's page, refreshed behind it; cache first for its
   fonts; stale-while-revalidate for everything else.

   The first version of this worker was cache-first with no revalidation, so an
   installed PWA kept serving whatever HTML it cached on the day it was
   installed until CACHE_NAME was edited by hand. The entire app is one HTML
   file, which made every release a two-file change where forgetting the second
   file shipped nothing at all - silently, and only to the users who had
   installed the app rather than bookmarked it.

   The second was network-first for the page. That fixed staleness by asking
   the network on every launch and waiting for the answer, so every launch,
   every theme reload of the installed iPhone app and every reboot after a
   wipe began with a round trip to the server, however unchanged the page.

   This one opens the page from the cache and asks the network afterwards. A
   copy that has changed is stored for the next launch and the page is told,
   so a launch that nobody has touched yet can move to it at once (see
   reloadIntoUpdate in index.html). A release is still a one-file change:
   nothing here names a version, because the refresh compares what the server
   sends with what is cached. */
const CACHE_NAME = "nodrift-v2";
const FONT_CACHE = "nodrift-fonts-v1";
const ASSETS_TO_CACHE = ["./", "./index.html", "./manifest.json", "./icon.svg"];

/* The app is one page, reached by two paths. Both open the one cached copy,
   so the home-screen icon ("./") and a bookmark of index.html never disagree
   about which version they show. */
const SHELL = new URL("./index.html", self.location.href).href;
const SHELL_PATHS = [
  new URL("./", self.location.href).pathname,
  new URL("./index.html", self.location.href).pathname,
];

/* Where Google Fonts keeps its files. Their URLs carry a version, so the
   bytes behind one never change and a stored copy never goes stale. */
const FONT_ORIGIN = "https://fonts.gstatic.com";

/* A hung request is worse than a stale one. On a captive portal or a dying
   mobile connection the fetch below can sit for the better part of a minute
   before the browser gives up, and until it does there is no page on screen
   at all. Past this deadline the cached copy is served and the network is
   left running to refresh the cache for next time. Only pages other than the
   app's own still wait on the network this way. */
const DOC_TIMEOUT_MS = 3500;

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => {
      return cache.addAll(ASSETS_TO_CACHE);
    }),
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((cacheNames) => {
      return Promise.all(
        cacheNames.map((cacheName) => {
          if (cacheName !== CACHE_NAME && cacheName !== FONT_CACHE) {
            return caches.delete(cacheName);
          }
        }),
      );
    }),
  );
  self.clients.claim();
});

/* The app's page, from the cache at once. The refresh runs on after the
   response, which is why it hangs off the event: only waitUntil keeps the
   worker alive long enough for it to land. With nothing cached -- an install
   that could not finish, or a cache the browser has cleared -- the network is
   the only answer there is, and its copy is kept as the page for next time. */
async function shellFirst(event) {
  const cache = await caches.open(CACHE_NAME);
  const cached = await cache.match(SHELL);
  if (cached) {
    event.waitUntil(refreshShell(cache, cached.headers));
    return cached;
  }
  const response = await networkFirst(event);
  if (response.ok) event.waitUntil(cache.put(SHELL, response.clone()));
  return response;
}

/* Asks the server for the page and keeps it if it has changed. no-cache
   makes the browser revalidate rather than answer from its own cache, so an
   unchanged page costs a 304 and nothing more. Every open window is told
   about a new copy; each decides for itself whether to reload into it. */
async function refreshShell(cache, cachedHeaders) {
  let fresh;
  try {
    fresh = await fetch(SHELL, { cache: "no-cache" });
  } catch (e) {
    return; // Offline: the copy that opened stands.
  }
  if (!fresh || !fresh.ok) return;
  if (await sameVersion(cache, cachedHeaders, fresh)) return;
  await cache.put(SHELL, fresh);
  const windows = await self.clients.matchAll({ type: "window" });
  windows.forEach((client) => client.postMessage({ type: "nodrift-update" }));
}

/* The validators the server sent with each copy, where both copies carry
   one; the pages themselves otherwise. */
async function sameVersion(cache, cachedHeaders, fresh) {
  for (const name of ["etag", "last-modified"]) {
    const was = cachedHeaders.get(name);
    const now = fresh.headers.get(name);
    if (was && now) return was === now;
  }
  const stored = await cache.match(SHELL);
  if (!stored) return false;
  const [was, now] = await Promise.all([stored.text(), fresh.clone().text()]);
  return was === now;
}

/* Takes the event rather than the request because a response served from the
   cache leaves a refresh in flight, and only waitUntil keeps the worker alive
   long enough for that refresh to reach the cache. */
async function networkFirst(event) {
  const request = event.request;
  const cache = await caches.open(CACHE_NAME);
  const network = fetch(request)
    .then((response) => {
      if (response && response.ok) cache.put(request, response.clone());
      return response;
    })
    .catch(() => null);

  /* Resolving to undefined rather than rejecting keeps the race below a plain
     "whichever is first" instead of a two-way error funnel. */
  const deadline = new Promise((resolve) =>
    setTimeout(resolve, DOC_TIMEOUT_MS),
  );
  const cached = await cache.match(request);

  if (cached) {
    const fresh = await Promise.race([network, deadline]);
    if (fresh) return fresh;
    /* The deadline won, so the refresh is still running. Without this the
       worker can be shut down the moment this response is handed back and
       the cache update never lands - which leaves a slow connection
       permanently stale rather than one launch behind. */
    event.waitUntil(network);
    return cached;
  }

  /* Nothing cached, so there is no faster answer to fall back to and the
     deadline would only turn a slow load into a failed one. */
  const fresh = await network;
  if (fresh) return fresh;

  /* A navigation to "/" or to a URL the cache has under a different key still
     wants the one HTML file this app consists of. */
  const shell = await cache.match("./index.html");
  if (shell) return shell;
  return Response.error();
}

async function staleWhileRevalidate(event) {
  const request = event.request;
  const cache = await caches.open(CACHE_NAME);
  const cached = await cache.match(request);
  const network = fetch(request)
    .then((response) => {
      if (response && response.ok) cache.put(request, response.clone());
      return response;
    })
    .catch(() => null);
  if (cached) {
    /* Revalidating is the whole point, and it only happens if the event
       outlives the response. */
    event.waitUntil(network);
    return cached;
  }
  const fresh = await network;
  return fresh || Response.error();
}

/* A font file is fetched once and kept: after its first use it comes from
   here, offline included, with no request at all. */
async function cacheFirst(event, cacheName) {
  const request = event.request;
  const cache = await caches.open(cacheName);
  const cached = await cache.match(request);
  if (cached) return cached;
  const fresh = await fetch(request);
  if (fresh && fresh.ok) event.waitUntil(cache.put(request, fresh.clone()));
  return fresh;
}

self.addEventListener("fetch", (event) => {
  const request = event.request;

  /* Supabase calls, and anything else that is not a plain GET for the app's
     own files or its fonts, are none of this worker's business. Passing them
     through untouched rather than wrapping them keeps auth and sync failures
     readable: a caching layer in the middle turns a 401 into an opaque
     miss. */
  if (request.method !== "GET") return;
  let url;
  try {
    url = new URL(request.url);
  } catch (e) {
    return;
  }
  if (url.origin === FONT_ORIGIN) {
    event.respondWith(cacheFirst(event, FONT_CACHE));
    return;
  }
  if (url.origin !== self.location.origin) return;

  if (request.mode === "navigate" && SHELL_PATHS.includes(url.pathname)) {
    event.respondWith(shellFirst(event));
    return;
  }
  const accept = request.headers.get("accept") || "";
  if (request.mode === "navigate" || accept.includes("text/html")) {
    event.respondWith(networkFirst(event));
    return;
  }
  event.respondWith(staleWhileRevalidate(event));
});
