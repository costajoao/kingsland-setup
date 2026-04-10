import setupScript from "./setup.sh";

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
