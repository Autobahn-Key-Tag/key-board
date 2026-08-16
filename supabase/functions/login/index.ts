// ============================================================================
// Key Board — login
// ============================================================================
//
// Exchanges an 8-digit code for a real Supabase session.
//
// WHY THIS EXISTS AT ALL: Row Level Security decides what a request may see
// based on who the *database* believes you are. Checking the code in the app's
// JavaScript would leave the database seeing an anonymous stranger, so every
// policy would have to allow anonymous access — which is no protection at all.
// The check has to happen somewhere the database trusts. This is that place.
//
// It is the only part of the system that touches the secret key, and the only
// part reachable without a session. Both facts make it the piece most worth
// reading carefully.
//
// Adapted from the dispatch login function. The differences are deliberate and
// noted where they occur; everything unremarked is the same because it was
// already right and diverging for its own sake would be a second thing to test.
//
// DEPLOYMENT NOTE: "Verify JWT" must be OFF for this function. It is the
// endpoint people call *before* they have a token, so requiring one is circular.
// That makes it publicly callable by design — the rate limiting below is what
// stands in for authentication.
// ============================================================================

import { createClient } from "npm:@supabase/supabase-js@2";

const URL = Deno.env.get("SUPABASE_URL")!;
const SECRET =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? Deno.env.get("KEYBOARD_SECRET_KEY")!;

// Synthetic addresses in a reserved TLD (RFC 2606) that is guaranteed never to
// resolve. Nobody receives mail here; the address is just the handle Supabase
// Auth needs internally. Nobody ever sees or types it.
//
// Distinct from dispatch's domain on purpose. These are different projects with
// different accounts, and identical-looking addresses in two dashboards is an
// invitation to reset the wrong one.
const EMAIL_DOMAIN = "keyboard.invalid";

// --- Lockout thresholds -----------------------------------------------------
//
// Three separate brakes, because they stop different things and have different
// costs when they misfire.
const WINDOW_MINUTES = 15;

// Per code. Stops someone patiently guessing at one specific code.
const MAX_PER_CODE = 5;

// Per IP address. The real brake on enumeration: working through the
// 100,000,000 possible codes from one address ends after fifteen tries.
//
// Dispatch sets this high enough for thirty staff to fumble at shift change on
// one office connection. Nobody logs into THIS app daily — the tablet and the
// television stay signed in, and a legitimate login here means somebody is
// setting a device up or recovering from a power cut. So the allowance is not
// doing the same job, and fifteen is generous rather than tight.
const MAX_PER_IP = 15;

// Everything, everywhere. A circuit breaker for an attacker rotating through
// many addresses. It SLOWS rather than blocks: a hard global lock would hand
// anyone a way to take the board offline with a few hundred bad guesses, and a
// cashier unable to sign the kiosk back in is a worse outcome than a slow
// attacker.
const GLOBAL_FAILURE_THRESHOLD = 200;
const GLOBAL_SLOWDOWN_MS = 1500;

// A NOTE ON WHAT THESE DO NOT PROTECT.
//
// The likeliest way the display code gets out is not guessing. It is typed onto
// a television in a room the public can walk into, and then that screen stays
// signed in for months. Rate limiting does nothing about somebody reading it
// over a shoulder, and it is not claimed to.
//
// What answers that is the account being worth nothing: the display can read the
// board and the advisor list, can write nothing at all, and the check constraint
// on `users` means it cannot be granted a write capability even by accident.
// See PLAN.md section 11.

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

// A one-way fingerprint of the submitted code, so attempts can be counted per
// code without the code itself ever being written down. This table leaking must
// not hand anybody a working credential.
//
// The prefix is project-specific: the same code used in both projects must not
// produce the same fingerprint, or one table's contents would say something
// about the other's.
async function fingerprint(code: string): Promise<string> {
  const bytes = new TextEncoder().encode(`key-board:${code}`);
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(hash)].map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 32);
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  if (!URL || !SECRET) {
    console.error("Missing SUPABASE_URL or secret key in function environment");
    return json({ error: "Login is misconfigured" }, 500);
  }

  // Which key is this actually using? Reported once per call, because a key of
  // the wrong KIND still works for some operations and not others, which is a
  // very confusing way to fail. Only the prefix is logged — never key material.
  {
    const fromServiceRole = !!Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const kind = SECRET.startsWith("sb_secret_")      ? "sb_secret_ (new-style secret)"
               : SECRET.startsWith("sb_publishable_") ? "sb_publishable_ — THIS IS THE WRONG KEY"
               : SECRET.startsWith("eyJ")             ? "legacy JWT"
               : "unrecognised";
    console.log(`auth key: ${kind}, from ${fromServiceRole
      ? "SUPABASE_SERVICE_ROLE_KEY" : "KEYBOARD_SECRET_KEY"}`);
  }

  const admin = createClient(URL, SECRET, { auth: { persistSession: false } });

  let code = "";
  try {
    code = String((await req.json())?.code ?? "").trim();
  } catch {
    return json({ error: "Bad request" }, 400);
  }

  // Shape check before touching the database. Note the deliberately vague
  // message: "must be 8 digits" is fine to say, but never say which part of a
  // submitted code was wrong.
  if (!/^[0-9]{8}$/.test(code)) {
    return json({ error: "Enter your 8-digit code" }, 400);
  }

  const ip =
    req.headers.get("x-forwarded-for")?.split(",")[0].trim() ??
    req.headers.get("cf-connecting-ip") ??
    "unknown";
  const fp = await fingerprint(code);
  const since = new Date(Date.now() - WINDOW_MINUTES * 60_000).toISOString();

  // --- Brakes ---------------------------------------------------------------
  const [byCode, byIp, global] = await Promise.all([
    admin.from("login_attempts").select("id", { count: "exact", head: true })
      .eq("code_fingerprint", fp).eq("succeeded", false).gte("at", since),
    admin.from("login_attempts").select("id", { count: "exact", head: true })
      .eq("ip", ip).eq("succeeded", false).gte("at", since),
    admin.from("login_attempts").select("id", { count: "exact", head: true })
      .eq("succeeded", false).gte("at", since),
  ]);

  const locked =
    (byCode.count ?? 0) >= MAX_PER_CODE || (byIp.count ?? 0) >= MAX_PER_IP;

  if ((global.count ?? 0) >= GLOBAL_FAILURE_THRESHOLD) await sleep(GLOBAL_SLOWDOWN_MS);

  if (locked) {
    await admin.from("login_attempts").insert({ ip, code_fingerprint: fp, succeeded: false });
    return json(
      { error: `Too many attempts. Try again in ${WINDOW_MINUTES} minutes.` },
      429,
    );
  }

  // --- Verify ---------------------------------------------------------------
  // The comparison happens inside Postgres against the salted hashes. This
  // function is not callable with the publishable key; exposed to the internet
  // it would be a brute-force oracle.
  const { data: userId, error: verifyErr } = await admin.rpc("verify_login_code", {
    p_code: code,
  });

  if (verifyErr) {
    console.error("verify_login_code failed:", verifyErr.message);
    return json({ error: "Login is temporarily unavailable" }, 500);
  }

  if (!userId) {
    await admin.from("login_attempts").insert({ ip, code_fingerprint: fp, succeeded: false });
    // Same message whether the code is unknown or belongs to a deactivated
    // account. Distinguishing them would confirm which codes are real — and
    // deactivating the kiosk is the answer to a stolen tablet, so "that code is
    // real but switched off" is precisely what a thief must not be told.
    return json({ error: "That code was not recognised" }, 401);
  }

  // --- Mint a session -------------------------------------------------------
  // Rather than storing a password we could replay, we ask Supabase Auth for a
  // single-use token for this user and immediately redeem it. generateLink does
  // not send any mail — the addresses do not resolve and nothing is delivered.
  const { data: authUser, error: getErr } = await admin.auth.admin.getUserById(userId);
  if (getErr || !authUser?.user?.email) {
    console.error("No auth user behind app user", userId, getErr?.message);
    return json({ error: "This account is not set up correctly" }, 500);
  }

  const { data: link, error: linkErr } = await admin.auth.admin.generateLink({
    type: "magiclink",
    email: authUser.user.email,
  });
  if (linkErr || !link?.properties?.hashed_token) {
    console.error("generateLink failed:", linkErr?.message);
    return json({ error: "Could not start your session" }, 500);
  }

  // A SEPARATE client, and this matters more than it looks.
  //
  // verifyOtp SIGNS THE CLIENT IN. Called on `admin`, it swaps that client's
  // secret key for the newly minted user's token, so every later .from() call
  // silently runs as `authenticated` instead of `service_role`.
  //
  // Dispatch hit this exactly: the success row is inserted AFTER this point, so
  // it ran as the freshly signed-in user — who has no grant on login_attempts —
  // and failed with "permission denied". Failed logins are recorded above this
  // line and worked fine, so the table filled with failures and no successes and
  // nothing anywhere said why. Kept separate here from the start.
  const sessionClient = createClient(URL, SECRET, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: session, error: otpErr } = await sessionClient.auth.verifyOtp({
    token_hash: link.properties.hashed_token,
    type: "email",
  });
  if (otpErr || !session?.session) {
    console.error("verifyOtp failed:", otpErr?.message);
    return json({ error: "Could not start your session" }, 500);
  }

  // The audit trail. Note this is inserted with `admin`, not `sessionClient`,
  // for the reason directly above.
  //
  // Nothing operational depends on this row — unlike dispatch, where it once
  // stood in for "who is on shift" and took notifications down with it when it
  // failed. It is still checked and shouted about, because a login record that
  // quietly does not exist is worth knowing about on its own account: this is a
  // three-account project, and a successful login nobody expected is a signal.
  const { error: attemptErr } = await admin.from("login_attempts").insert({
    ip, code_fingerprint: fp, succeeded: true, user_id: userId,
  });
  if (attemptErr) {
    console.error("COULD NOT RECORD LOGIN for", userId, ":", attemptErr.message);
  }

  // The profile comes back with the session so the app knows which screen to
  // draw on first paint. It is a convenience, not a permission: what a screen
  // offers is cosmetic, and every action is re-checked by the database.
  //
  // is_display is what tells the front end not to expire this session overnight.
  // A television that logs itself out at 3am is a blank wall every morning until
  // somebody finds a keyboard.
  const { data: profile } = await admin
    .from("users")
    .select("id, name, can_handle_keys, is_display, is_admin")
    .eq("id", userId)
    .single();

  return json({
    access_token: session.session.access_token,
    refresh_token: session.session.refresh_token,
    expires_at: session.session.expires_at,
    user: profile,
  });
});
