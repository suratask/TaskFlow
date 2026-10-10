// Serves only TaskFlow Notes on the web (/notes*). See wrangler.jsonc.
const HEADERS = {
  'Content-Security-Policy': "default-src 'self'; script-src 'self' https://cdn.apple-cloudkit.com; connect-src 'self' https://*.apple-cloudkit.com https://*.icloud.com https://*.apple.com; frame-src https://*.icloud.com https://*.apple.com; img-src 'self' data: https://*.apple.com https://*.icloud.com https://*.apple-cloudkit.com; style-src 'self' 'unsafe-inline'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'",
  'Referrer-Policy': 'no-referrer',
  'X-Content-Type-Options': 'nosniff',
  'Cache-Control': 'no-store',
  'X-Robots-Tag': 'noindex',
  'X-Served-By': 'taskflow-notes'
};

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    // iCloud sign-in is registered for modcaststudios.app only. A different
    // host, so a temporary redirect here can't loop.
    if (url.hostname !== 'modcaststudios.app') {
      url.hostname = 'modcaststudios.app';
      return Response.redirect(url.toString(), 302);
    }
    // The page has always been at /notes, and browsers keep the site's old
    // permanent /notes/ -> /notes redirect cached; this is the same direction.
    if (url.pathname === '/notes/') {
      url.pathname = '/notes';
      return Response.redirect(url.toString(), 301);
    }
    let response;
    if (url.pathname === '/notes' || url.pathname === '/notes.html') {
      url.pathname = '/notes.html';
      const page = await env.ASSETS.fetch(new Request(url, request));
      response = new Response(page.body, {status: page.status, headers: page.headers});
      response.headers.set('Content-Type', 'text/html; charset=utf-8');
    } else if (url.pathname.startsWith('/notes/')) {
      response = await env.ASSETS.fetch(request);
    } else {
      // Anything else under the route (such as the old flat notes-*.mjs files)
      // isn't part of this page.
      response = new Response('Not found', {status: 404});
    }
    const headers = new Headers(response.headers);
    for (const [name, value] of Object.entries(HEADERS)) headers.set(name, value);
    return new Response(response.body, {status: response.status, statusText: response.statusText, headers});
  }
};
