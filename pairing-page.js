// Writes the web client page that Che's editor URL serves. Che's gateway asks for the Che
// login before it forwards anything to orcad, so the page can carry orcad's runtime pairing
// token, and Orca's web client pairs on load instead of asking for a pairing URL.
//
// Usage: pairing-page.js <template web-index.html> <output web-index.html> < readiness line
const fs = require('node:fs')

const [templatePath, outputPath] = process.argv.slice(2)
const ready = JSON.parse(fs.readFileSync(0, 'utf8'))
if (!ready.pairing?.available) {
  throw new Error(`orcad has no pairing offer: ${ready.pairing?.reason ?? 'unknown'}`)
}
const code = new URL(ready.pairing.url).searchParams.get('code')
const { deviceToken, publicKeyB64, pairedDeviceId } = JSON.parse(
  Buffer.from(code, 'base64url').toString('utf8')
)

// Runs in the browser before the web client. The endpoint comes from the page URL because
// the gateway forwards WebSockets on the editor's path, and orcad accepts them on any path.
function pairFromPage(offer) {
  if (location.hash || location.search) {
    return
  }
  const endpoint = new URL('./', location.href)
  endpoint.protocol = endpoint.protocol === 'https:' ? 'wss:' : 'ws:'
  try {
    const stored = JSON.parse(localStorage.getItem('orca.web.runtimeEnvironment.v1'))
    // Every auto-pair creates a new environment, so pair only when this one is not stored.
    if (stored.endpoints.some((e) => e.endpoint === endpoint.href && e.deviceToken === offer.deviceToken)) {
      return
    }
  } catch {}
  const payload = JSON.stringify({ v: 2, endpoint: endpoint.href, ...offer, scope: 'runtime' })
  const pairingCode = btoa(payload).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
  history.replaceState(
    null,
    '',
    `${location.pathname}#pairing=${encodeURIComponent(`orca://pair?code=${pairingCode}`)}`
  )
}

const offer = JSON.stringify({ deviceToken, publicKeyB64, ...(pairedDeviceId ? { pairedDeviceId } : {}) })
const script = `<script>(${pairFromPage})(${offer.replace(/</g, '\\u003c')})</script>`
const template = fs.readFileSync(templatePath, 'utf8')
if (!template.includes('</head>')) {
  throw new Error(`${templatePath} has no </head>`)
}
// The client is a module script, which runs after parsing, so the offer is in place first.
const temporary = `${outputPath}.tmp`
fs.writeFileSync(temporary, template.replace('</head>', `${script}</head>`), { mode: 0o600 })
fs.renameSync(temporary, outputPath)
