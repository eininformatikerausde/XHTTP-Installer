// Vercel Edge Function — XHTTP Relay
// by avaco_cloud
export const config = { runtime: 'edge' };

const TARGET = process.env.TARGET_DOMAIN;        // e.g. "ns.example.com:443"
const UPSTREAM = process.env.UPSTREAM_PROTOCOL || 'https';
const RELAY_PATH = process.env.RELAY_PATH || '/api';

export default async function handler(req) {
  if (!TARGET) {
    return new Response('Misconfigured: TARGET_DOMAIN not set', { status: 500 });
  }

  const url = new URL(req.url);
  const targetUrl = `${UPSTREAM}://${TARGET}${url.pathname}${url.search}`;

  const headers = new Headers(req.headers);
  headers.set('host', TARGET.split(':')[0]);
  // Remove headers that might cause issues
  headers.delete('x-forwarded-for');
  headers.delete('x-real-ip');

  try {
    const upstream = await fetch(targetUrl, {
      method: req.method,
      headers,
      body: ['GET', 'HEAD'].includes(req.method) ? undefined : req.body,
      redirect: 'follow',
    });

    return new Response(upstream.body, {
      status: upstream.status,
      headers: upstream.headers,
    });
  } catch (e) {
    return new Response('Bad Gateway: ' + e.message, { status: 502 });
  }
}
