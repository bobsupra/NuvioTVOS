type JsonValue =
  | string
  | number
  | boolean
  | null
  | JsonValue[]
  | { [key: string]: JsonValue };

const TRAKT_API_URL = stripTrailingSlash(
  Deno.env.get("TRAKT_API_URL") || "https://api.trakt.tv",
);
const TRAKT_CLIENT_ID = Deno.env.get("TRAKT_CLIENT_ID") || "";
const TRAKT_CLIENT_SECRET = Deno.env.get("TRAKT_CLIENT_SECRET") || "";
const TRAKT_REDIRECT_URI =
  Deno.env.get("TRAKT_REDIRECT_URI") || "urn:ietf:wg:oauth:2.0:oob";

const corsHeaders = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers":
    "authorization, x-client-info, apikey, content-type, x-trakt-access-token",
  "access-control-allow-methods": "GET, POST, OPTIONS",
};

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (!TRAKT_CLIENT_ID || !TRAKT_CLIENT_SECRET) {
    return jsonResponse(
      { error: "Trakt proxy is missing TRAKT_CLIENT_ID or TRAKT_CLIENT_SECRET" },
      500,
    );
  }

  const url = new URL(request.url);
  const route = routeAfterFunctionName(url.pathname, "trakt");

  try {
    if (request.method === "GET" && route === "") {
      return jsonResponse({
        ok: true,
        configured: Boolean(TRAKT_CLIENT_ID && TRAKT_CLIENT_SECRET),
      }, 200);
    }

    if (request.method === "POST" && route === "oauth/device/code") {
      return await forwardTrakt(request, route, {
        client_id: TRAKT_CLIENT_ID,
      });
    }

    if (request.method === "POST" && route === "oauth/device/token") {
      const body = await requestJson(request);
      return await forwardTrakt(request, route, {
        ...body,
        client_id: TRAKT_CLIENT_ID,
        client_secret: TRAKT_CLIENT_SECRET,
      });
    }

    if (request.method === "POST" && route === "oauth/token") {
      const body = await requestJson(request);
      return await forwardTrakt(request, route, {
        ...body,
        client_id: TRAKT_CLIENT_ID,
        client_secret: TRAKT_CLIENT_SECRET,
        redirect_uri: TRAKT_REDIRECT_URI,
      });
    }

    if (request.method === "POST" && route === "oauth/revoke") {
      const body = await requestJson(request);
      return await forwardTrakt(request, route, {
        ...body,
        client_id: TRAKT_CLIENT_ID,
        client_secret: TRAKT_CLIENT_SECRET,
      });
    }

    if (
      request.method === "GET" &&
      (route === "users/settings" || /^users\/[^/]+\/stats$/.test(route))
    ) {
      const token = request.headers.get("x-trakt-access-token") || "";
      if (!token) {
        return jsonResponse({ error: "Missing X-Trakt-Access-Token" }, 401);
      }
      return await forwardTrakt(request, route, undefined, token);
    }

    // Details enrichment: comments, related titles, and tmdb id search.
    // Only allow known-safe read paths so the proxy stays a narrow gate.
    if (request.method === "GET" && isAllowedDetailsRoute(route)) {
      const token = request.headers.get("x-trakt-access-token") || "";
      if (!token) {
        return jsonResponse({ error: "Missing X-Trakt-Access-Token" }, 401);
      }
      return await forwardTrakt(request, route, undefined, token);
    }

    if (request.method === "GET" && route === "account/session") {
      return jsonResponse(
        {
          error:
            "No account-level Trakt session is available from this proxy yet",
        },
        404,
      );
    }

    return jsonResponse({ error: "Unknown Trakt proxy route" }, 404);
  } catch (error) {
    const message = error instanceof Error ? error.message : "Proxy failed";
    return jsonResponse({ error: message }, 500);
  }
});

async function forwardTrakt(
  request: Request,
  route: string,
  body?: Record<string, JsonValue>,
  accessToken?: string,
): Promise<Response> {
  // Preserve client query string (page/limit/extended/type) for allowlisted GETs.
  const search = new URL(request.url).search || "";
  const pathOnly = route.split("?")[0];
  const upstream = await fetch(`${TRAKT_API_URL}/${pathOnly}${search}`, {
    method: request.method,
    headers: traktHeaders(accessToken),
    body: body === undefined ? undefined : JSON.stringify(body),
  });

  const responseBody = await upstream.text();
  return new Response(responseBody, {
    status: upstream.status,
    headers: {
      ...corsHeaders,
      "content-type":
        upstream.headers.get("content-type") || "application/json",
    },
  });
}

function traktHeaders(accessToken?: string): HeadersInit {
  const headers: Record<string, string> = {
    "content-type": "application/json",
    "trakt-api-key": TRAKT_CLIENT_ID,
    "trakt-api-version": "2",
  };
  if (accessToken) {
    headers.authorization = `Bearer ${accessToken}`;
  }
  return headers;
}

async function requestJson(request: Request): Promise<Record<string, JsonValue>> {
  const text = await request.text();
  if (!text) { return {}; }
  const value = JSON.parse(text);
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Expected a JSON object body");
  }
  return value as Record<string, JsonValue>;
}

function routeAfterFunctionName(pathname: string, functionName: string): string {
  const parts = pathname.split("/").filter(Boolean);
  const index = parts.lastIndexOf(functionName);
  if (index < 0) { return ""; }
  return parts.slice(index + 1).join("/");
}

function stripTrailingSlash(value: string): string {
  return value.replace(/\/+$/, "");
}

/** Allowlisted GET routes for details (comments / related / id lookup). */
function isAllowedDetailsRoute(route: string): boolean {
  const path = route.split("?")[0];
  if (/^(movies|shows)\/[^/]+\/comments(\/[^/]+)?$/.test(path)) {
    return true;
  }
  if (/^(movies|shows)\/[^/]+\/related$/.test(path)) {
    return true;
  }
  if (/^search\/tmdb\/\d+$/.test(path)) {
    return true;
  }
  return false;
}

function jsonResponse(body: Record<string, JsonValue>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "content-type": "application/json" },
  });
}
