/* Network-first for the document, stale-while-revalidate for everything else.

   The first version of this worker was cache-first with no revalidation, so an
   installed PWA kept serving whatever HTML it cached on the day it was
   installed until CACHE_NAME was edited by hand. The entire app is one HTML
   file, which made every release a two-file change where forgetting the second
   file shipped nothing at all - silently, and only to the users who had
   installed the app rather than bookmarked it. */
const CACHE_NAME = "nodrift-v2";
const ASSETS_TO_CACHE = ["./", "./index.html", "./manifest.json", "./icon.svg"];

/* A hung request is worse than a stale one. On a captive portal or a dying
   mobile connection the fetch below can sit for the better part of a minute
   before the browser gives up, and until it does there is no app on screen at
   all. Past this deadline the cached copy is served and the network is left
   running to refresh the cache for next launch, so a bad connection costs one
   launch of staleness rather than a blank screen. */
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
          if (cacheName !== CACHE_NAME) {
            return caches.delete(cacheName);
          }
        }),
      );
    }),
  );
  self.clients.claim();
});

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

self.addEventListener("fetch", (event) => {
  const request = event.request;

  /* Supabase calls, and anything else that is not a plain same-origin GET, are
     none of this worker's business. Passing them through untouched rather than
     wrapping them keeps auth and sync failures readable: a caching layer in
     the middle turns a 401 into an opaque miss. */
  if (request.method !== "GET") return;
  let url;
  try {
    url = new URL(request.url);
  } catch (e) {
    return;
  }
  if (url.origin !== self.location.origin) return;

  const accept = request.headers.get("accept") || "";
  if (request.mode === "navigate" || accept.includes("text/html")) {
    event.respondWith(networkFirst(event));
    return;
  }
  event.respondWith(staleWhileRevalidate(event));
});
