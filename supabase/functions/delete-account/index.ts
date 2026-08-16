/* delete-account -- the one thing the app cannot do for itself.
 *
 * Removing a row from `records` is an ordinary authenticated request, but
 * removing the *account* means deleting from `auth.users`, and that is only
 * permitted to the service-role key. A key with that power can read and
 * rewrite every user's data, so it can never be in the page: the app is
 * static, its source is public, and anything shipped to the browser is
 * readable by whoever it is shipped to. This function is where such a key
 * can live -- on Supabase's own runtime, holding it in an environment
 * variable the platform injects and nobody has to paste anywhere.
 *
 * The security property this file exists to hold:
 *
 *   The user id being deleted comes from the *verified JWT*, never from the
 *   request. Accept an id from the body and this endpoint deletes anybody's
 *   account for anybody who asks -- authentication would prove only that the
 *   caller is *a* user, not that they are *that* user.
 *
 * No supabase-js. Two plain fetches do the whole job, which is the same
 * reasoning section 3 of docs/SYNC-BLUEPRINT.md applies to the app itself,
 * and it keeps a third-party dependency out of the one place in this project
 * that holds the service-role key.
 *
 * Deploy:
 *   npx supabase functions deploy delete-account --project-ref <ref>
 * or paste this file into Edge Functions -> Deploy a new function in the
 * dashboard. SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY
 * are injected by the platform; none of them need to be set by hand.
 */

/* Named origins rather than "*". The JWT is what actually protects this
 * endpoint, so this is not the security boundary -- but there is no reason
 * for a page nobody wrote to be able to call it, and the local entries are
 * what let the test harness drive it from a served copy of the app. */
const ALLOWED_ORIGINS = [
  "https://nodrift.vercel.app",
  "http://127.0.0.1:8833",
  "http://localhost:8833",
];

function cors(origin: string | null): Record<string, string> {
  const allow =
    origin && ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0];
  return {
    "Access-Control-Allow-Origin": allow,
    "Access-Control-Allow-Headers":
      "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    Vary: "Origin",
  };
}

function json(body: unknown, status: number, origin: string | null): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors(origin), "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request): Promise<Response> => {
  const origin = req.headers.get("Origin");

  /* The app sends Authorization and apikey, which makes this a preflighted
   * request: without an answer here the real POST is never sent, and the
   * browser reports it as a network failure with no status to read. */
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: cors(origin) });
  }
  if (req.method !== "POST") {
    return json({ message: "Method not allowed" }, 405, origin);
  }

  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY");
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anon || !service) {
    return json({ message: "Function is not configured" }, 500, origin);
  }

  const auth = req.headers.get("Authorization") || "";
  if (!auth.startsWith("Bearer ")) {
    return json({ message: "Not signed in" }, 401, origin);
  }

  /* Step one: who is calling, according to the auth server rather than
   * according to them. A forged or expired token dies here. */
  const whoami = await fetch(`${url}/auth/v1/user`, {
    headers: { Authorization: auth, apikey: anon },
  });
  if (!whoami.ok) {
    return json({ message: "Not signed in" }, 401, origin);
  }
  const user = await whoami.json().catch(() => null);
  if (!user || typeof user.id !== "string" || !user.id) {
    return json({ message: "Not signed in" }, 401, origin);
  }

  /* Step two: delete that id and only that id. records, session_state and
   * devices all reference auth.users ON DELETE CASCADE, so this one call
   * takes the rows with it -- see supabase/migrations/0001_schema.sql. */
  const gone = await fetch(
    `${url}/auth/v1/admin/users/${encodeURIComponent(user.id)}`,
    {
      method: "DELETE",
      headers: { Authorization: `Bearer ${service}`, apikey: service },
    },
  );
  if (!gone.ok) {
    const detail = await gone.text().catch(() => "");
    console.error("admin delete failed", gone.status, detail);
    /* The reason is logged, not returned: it is about the project, not
     * about the caller, and this response is read by a browser. */
    return json({ message: "Could not delete the account" }, 502, origin);
  }

  return json({ deleted: true }, 200, origin);
});
