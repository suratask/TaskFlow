// Serves only TaskFlow Notes on the web (/notes*). See wrangler.jsonc.
const HEADERS = {
  'Content-Security-Policy': "default-src 'self'; script-src 'self' https://cdn.apple-cloudkit.com; connect-src 'self' https://*.apple-cloudkit.com https://*.icloud.com https://*.apple.com; frame-src https://*.icloud.com https://*.apple.com; img-src 'self' data: https://*.apple.com https://*.icloud.com https://*.apple-cloudkit.com; style-src 'self' 'unsafe-inline'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'",
  'Referrer-Policy': 'no-referrer',
  'X-Content-Type-Options': 'nosniff',
  'Cache-Control': 'no-store',
  'X-Robots-Tag': 'noindex',
  'X-Served-By': 'taskflow-notes'
};

/// Keeps the iCloud sign-in. CloudKit JS saves its session in a cookie written
/// from script: 14 days, no Path (so the page's folder), and Safari cuts script
/// cookies to 7 days. When a page request carries exactly one copy, it's sent
/// back as a server cookie good for 400 days, with the same name and path so it
/// replaces that copy instead of adding a second (two copies break sign-in,
/// "Could not read or write ckSession"). Nothing is stored here; signing out
/// still deletes it, since CloudKit clears the same cookie.
const SESSION_COOKIE = 'iCloud.com.surratt.TaskFlow';
const SESSION_PATH = '/';
const KEEP_SECONDS = 400 * 24 * 3600;
function keepSession(request, headers) {
  const copies = (request.headers.get('Cookie') || '').split(/;\s*/).filter(part => part.startsWith(SESSION_COOKIE + '='));
  if (copies.length !== 1) return;
  const value = copies[0].slice(SESSION_COOKIE.length + 1);
  if (!value || value === 'null' || /[\s;,]/.test(value)) return;
  headers.append('Set-Cookie', `${SESSION_COOKIE}=${value}; Max-Age=${KEEP_SECONDS}; Path=${SESSION_PATH}; Secure; SameSite=Lax`);
}

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
    if (url.pathname === '/notes.html') keepSession(request, headers);
    return new Response(response.body, {status: response.status, statusText: response.statusText, headers});
  }
};
