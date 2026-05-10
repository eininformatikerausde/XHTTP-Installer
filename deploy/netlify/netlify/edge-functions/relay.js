// Netlify Edge Function — XHTTP Relay
// by avaco_cloud

export default async (request, context) => {
  const target = Deno.env.get('TARGET_DOMAIN'); // e.g. "ns.example.com:443"

  if (!target) {
    return new Response('Misconfigured: TARGET_DOMAIN not set', { status: 500 });
  }

  const url = new URL(request.url);
  const upstream = `https://${target}${url.pathname}${url.search}`;

  const headers = new Headers(request.headers);
  headers.set('host', target.split(':')[0]);
  headers.delete('x-forwarded-for');
  headers.delete('x-real-ip');

  try {
    const resp = await fetch(upstream, {
      method: request.method,
      headers,
      body: ['GET', 'HEAD'].includes(request.method) ? undefined : request.body,
    });

    return new Response(resp.body, {
      status: resp.status,
      headers: resp.headers,
    });
  } catch (e) {
    return new Response('Bad Gateway: ' + e.message, { status: 502 });
  }
};

export const config = { path: '/*' };
