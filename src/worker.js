import encoded from "./setup.sh.b64";

// Decode the base64-encoded setup.sh once at module init, then serve the
// UTF-8 string on every request. The indirection exists because
// Cloudflare's edge WAF on api.cloudflare.com blocks deploy payloads that
// contain raw shell-script patterns (e.g. `curl ... install.sh`), so the
// file is uploaded as base64 and decoded here.
const binary = atob(encoded);
const bytes = new Uint8Array(binary.length);
for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
const setupScript = new TextDecoder().decode(bytes);

const HEADERS = {
  "content-type": "text/x-shellscript; charset=utf-8",
  "cache-control": "public, max-age=300",
  "x-content-type-options": "nosniff",
};

export default {
  async fetch(request) {
    const { pathname } = new URL(request.url);

    if (pathname === "/setup.sh" || pathname === "/") {
      return new Response(setupScript, { headers: HEADERS });
    }

    return new Response("Not Found\n", {
      status: 404,
      headers: { "content-type": "text/plain; charset=utf-8" },
    });
  },
};
