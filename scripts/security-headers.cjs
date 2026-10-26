// Regenerate after changing inline application scripts. Does not deploy.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const root = path.resolve(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'public/index.html'), 'utf8').replace(/\r\n/g, '\n');
const hashes = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)]
  .filter(match => !/\bsrc\s*=/i.test(match[1]))
  .map(match => "'sha256-" + crypto.createHash('sha256').update(match[2]).digest('base64') + "'");
const policy = "default-src 'self'; script-src 'self' " + hashes.join(' ') +
  "; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' https://zhshcpkgvijbznetfseu.supabase.co wss://zhshcpkgvijbznetfseu.supabase.co; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'";
const headers = [
  { key: 'Content-Security-Policy', value: policy },
  { key: 'X-Frame-Options', value: 'DENY' },
  { key: 'X-Content-Type-Options', value: 'nosniff' },
  { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
  { key: 'Permissions-Policy', value: 'camera=(), microphone=(), geolocation=()' },
];
fs.writeFileSync(path.join(root, 'vercel.json'), JSON.stringify({
  $schema: 'https://openapi.vercel.sh/vercel.json', framework: null, outputDirectory: 'public',
  headers: [{ source: '/(.*)', headers }],
}, null, 2) + '\n');
fs.writeFileSync(path.join(root, 'public/_headers'), '/*\n' + headers.map(header => '  ' + header.key + ': ' + header.value).join('\n') + '\n');
console.log('Generated Vercel and Netlify security headers for the current inline scripts.');
