/**
 * Controlled test page with an authoritative server-side submission counter.
 * Unauthenticated by design: the phone loads it like any website. Never expose
 * it on a public relay.
 */
export function createCounterFixture() {
  let count = 0;
  let lastNote = null;

  const page = () => `<!doctype html>
<html><head><meta name="viewport" content="width=device-width, initial-scale=1"><title>Counter fixture</title></head>
<body>
  <h1>Counter fixture</h1>
  <form method="post" action="/fixtures/counter/submit">
    <label for="note">Note</label>
    <input id="note" name="note" placeholder="Type a note">
    <button type="submit">Submit note</button>
  </form>
  <p id="count">Submissions: ${count}</p>
  <p id="last">Last note: ${lastNote === null ? "(none)" : escapeHtml(lastNote)}</p>
</body></html>`;

  return {
    handle(request, response, url, body) {
      if (url.pathname === "/fixtures/counter" && request.method === "GET") {
        response.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
        response.end(page());
        return true;
      }
      if (url.pathname === "/fixtures/counter/submit" && request.method === "POST") {
        count += 1;
        lastNote = new URLSearchParams(body).get("note");
        response.writeHead(303, { location: "/fixtures/counter" });
        response.end();
        return true;
      }
      if (url.pathname === "/fixtures/counter/state" && request.method === "GET") {
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({ count, lastNote }));
        return true;
      }
      if (url.pathname === "/fixtures/counter/reset" && request.method === "POST") {
        count = 0;
        lastNote = null;
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({ count }));
        return true;
      }
      return false;
    },
  };
}

function escapeHtml(text) {
  return String(text).replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]);
}
