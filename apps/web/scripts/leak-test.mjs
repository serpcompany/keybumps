#!/usr/bin/env node
// Headless-browser check that Polar's checkout and customer-session parameters never reach GTM,
// GA, or the dataLayer, and that /thanks/ and /license/ still load GTM (#151). Run it with
// `pnpm test:leak` on every Next.js or OpenNext upgrade: the protection relies on router
// internals that unit tests can't exercise (src/lib/sensitive-url-routes.ts).
//
// By default it builds a production-mode site (SITE_ENV=production, a placeholder GTM ID),
// serves it with `opennextjs-cloudflare preview`, and runs every scenario against it. Pass
// `--base <url>` to test a preview that is already running in production mode instead.
//
// Every request to another origin is captured and blocked. gtm.js is answered with a local
// stand-in that records what a tag could read when GTM starts (location, document.URL, referrer,
// history.state, Navigation API entries, performance entries, the RSC payload, and the HTML),
// emulates GTM's history-change trigger, and sends a GA-style collect request for every page view.
// The test values are obvious placeholders.
//
// Options: --base <url>, --port <n> (default 8793), and CHROME_PATH to use a specific Chrome
// (otherwise the installed Google Chrome channel).
import { spawn } from 'node:child_process'
import { createServer } from 'node:net'
import { parseArgs } from 'node:util'
import { chromium } from 'playwright-core'

const { values: options } = parseArgs({
  options: { base: { type: 'string' }, port: { type: 'string', default: '8793' } }
})
const SECRET = 'FAKE_SECRET_LEAK'
const CHECKOUT = 'FAKE_CHECKOUT_LEAK'
const Q = `checkout_id=${CHECKOUT}&customer_session_token=${SECRET}`
const GTM_ID = 'GTM-TEST123'

// --- Preview server -------------------------------------------------------------------------

let server = null
function run(command, args, env) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { env: { ...process.env, ...env }, stdio: 'inherit' })
    child.on('exit', code =>
      code === 0 ? resolve() : reject(new Error(`${command} exited ${code}`))
    )
  })
}
/** Resolves if nothing listens on `port` on either loopback address, and rejects otherwise. */
async function assertPortFree(port) {
  for (const host of ['127.0.0.1', '::1']) {
    await new Promise((resolve, reject) => {
      const probe = createServer()
      probe.once('error', error => {
        // No IPv6 loopback on this machine: nothing can be listening there.
        if (error.code === 'EADDRNOTAVAIL' || error.code === 'EAFNOSUPPORT') resolve()
        else reject(new Error(`port ${port} is already in use on ${host} (${error.code})`))
      })
      probe.listen({ port: Number(port), host, exclusive: true }, () => probe.close(resolve))
    })
  }
}

async function startPreview(port) {
  // A server already on the port would answer the readiness check, and the test would run
  // against it instead of this build, so refuse to start. Checked before the build (fail fast)
  // and again right before the preview starts.
  const busy = error => {
    throw new Error(
      `${error.message}. Stop whatever is running there, or pass --port <free port>, or ` +
        '--base <url> to test a production-mode preview you started yourself.'
    )
  }
  await assertPortFree(port).catch(busy)
  const env = { SITE_ENV: 'production', NEXT_PUBLIC_GTM_ID: GTM_ID }
  console.log('Building a production-mode site…')
  await run('pnpm', ['exec', 'opennextjs-cloudflare', 'build'], env)
  await assertPortFree(port).catch(busy)
  console.log(`Starting the preview on port ${port}…`)
  const output = []
  const keep = chunk => {
    output.push(...chunk.toString().split('\n'))
    output.splice(0, Math.max(0, output.length - 200))
  }
  server = spawn(
    'pnpm',
    ['exec', 'opennextjs-cloudflare', 'preview', '--port', port, '--var', 'SITE_ENV:production'],
    { env: { ...process.env, ...env }, stdio: ['ignore', 'pipe', 'pipe'], detached: true }
  )
  server.stdout.on('data', keep)
  server.stderr.on('data', keep)
  const exited = new Promise(resolve => server.once('exit', code => resolve(code)))
  const failed = reason => {
    console.error(`The preview's output (last ${output.length} lines):\n${output.join('\n')}`)
    return new Error(`the preview did not start: ${reason}`)
  }
  const base = `http://localhost:${port}`
  for (let i = 0; i < 120; i++) {
    const code = await Promise.race([
      exited,
      new Promise(r => setTimeout(() => r('running'), 1000))
    ])
    if (code !== 'running') throw failed(`it exited with code ${code}`)
    try {
      if ((await fetch(`${base}/`)).ok) return base
    } catch {}
  }
  throw failed('no 200 from / within 120 s')
}
function stopPreview() {
  if (server) {
    try {
      process.kill(-server.pid)
    } catch {}
    server = null
  }
}
process.on('exit', stopPreview)
process.on('SIGINT', () => process.exit(130))

// --- GTM stand-in ---------------------------------------------------------------------------

const stub = `(function () {
  var dl = (window.dataLayer = window.dataLayer || [])
  var read = function (f) { try { return f() } catch (e) { return 'unavailable' } }
  dl.push({ event: 'stub.gtm.start', 'stub.seen': {
    location: location.href,
    url: document.URL,
    referrer: document.referrer,
    baseURI: document.baseURI,
    state: read(function () { return JSON.stringify(history.state) }),
    navigationEntries: read(function () { return navigation.entries().map(function (e) { return e.url }) }),
    performance: read(function () { return performance.getEntries().map(function (e) { return e.name }) }),
    rscPayload: read(function () { return JSON.stringify(self.__next_f) }),
    html: document.documentElement.outerHTML
  } })
  var collect = function () {
    new Image().src = 'https://www.google-analytics.com/g/collect?en=page_view&dl=' +
      encodeURIComponent(location.href) + '&dr=' + encodeURIComponent(document.referrer)
  }
  collect()
  var oldUrl = location.href, oldState = history.state
  var change = function (source) {
    dl.push({ event: 'gtm.historyChange-v2', 'gtm.historyChangeSource': source, 'gtm.oldUrl': oldUrl,
      'gtm.newUrl': location.href, 'gtm.oldHistoryState': oldState, 'gtm.newHistoryState': history.state })
    if (location.href !== oldUrl) collect()
    oldUrl = location.href
    oldState = history.state
  }
  ;['pushState', 'replaceState'].forEach(function (name) {
    var original = history[name]
    history[name] = function () { var r = original.apply(this, arguments); change(name); return r }
  })
  addEventListener('popstate', function () { change('popstate') })
})()`

// --- Test harness ---------------------------------------------------------------------------

const results = []
const check = (name, ok, detail) => {
  results.push({ ok, name })
  console.log(
    `${ok ? 'PASS' : 'FAIL'}  ${name}${ok || detail === undefined ? '' : `  ${JSON.stringify(detail)}`}`
  )
}
const hasSecret = text => text.includes(SECRET) || text.includes(CHECKOUT)

let runWideChecksDue = false // set once request capture is installed
const external = []
const pushes = []
const tokenResponses = [] // same-origin responses whose request URL carried the test values

// The checks across every scenario. They also run when a scenario crashes, so a crash never hides
// a leak from the scenarios before it.
function runWideChecks() {
  runWideChecksDue = false
  const leakedRequests = external.filter(hasSecret)
  check(
    'no external request (URL, Referer, body) carries the test values',
    leakedRequests.length === 0,
    leakedRequests
  )
  const leakedPushes = pushes.filter(hasSecret)
  check(
    'no dataLayer push carries the test values',
    leakedPushes.length === 0,
    leakedPushes.map(p => p.slice(0, 300))
  )
  const served = tokenResponses.filter(r => r.startsWith('200'))
  check(
    'the site never serves a 200 for a URL with the test values',
    served.length === 0,
    tokenResponses
  )
}

async function main() {
  const B = options.base?.replace(/\/$/, '') ?? (await startPreview(options.port))
  const sensitivePath = path => /^\/(thanks|license)\/?$/.test(path)
  const browser = await chromium.launch(
    process.env.CHROME_PATH
      ? { executablePath: process.env.CHROME_PATH, headless: true }
      : { channel: 'chrome', headless: true }
  )
  const context = await browser.newContext()
  const page = await context.newPage()

  const sensitiveRsc = [] // RSC requests for /thanks/ or /license/ (prefetch noise)

  await context.route('**/*', route => {
    const request = route.request()
    const url = request.url()
    if (url.startsWith(B)) return route.continue()
    external.push([url, request.headers().referer ?? '', request.postData() ?? ''].join(' '))
    if (/googletagmanager\.com\/gtm\.js/.test(url)) {
      return route.fulfill({ status: 200, contentType: 'application/javascript', body: stub })
    }
    return route.abort()
  })
  let documentRequests = 0 // main-frame navigations, counted to spot one during a check
  page.on('request', request => {
    if (request.isNavigationRequest() && request.frame() === page.mainFrame()) documentRequests++
  })
  page.on('response', response => {
    const request = response.request()
    if (!request.url().startsWith(B)) return
    const url = new URL(request.url())
    if (hasSecret(request.url()))
      tokenResponses.push(`${response.status()} ${request.resourceType()}`)
    if (request.headers().rsc && sensitivePath(url.pathname)) {
      sensitiveRsc.push({
        page: page.url(),
        path: url.pathname,
        prefetch: !!request.headers()['next-router-prefetch']
      })
    }
  })
  await context.exposeBinding('__recordPush', (_source, entry) => pushes.push(entry))
  await context.addInitScript(() => {
    const wrap = array => {
      const push = array.push
      array.push = function (...items) {
        for (const item of items) {
          try {
            window.__recordPush(JSON.stringify(item))
          } catch {
            window.__recordPush(String(item))
          }
        }
        return push.apply(this, items)
      }
      return array
    }
    let current = wrap([])
    Object.defineProperty(window, 'dataLayer', {
      configurable: true,
      get: () => current,
      set: value => {
        if (value !== current) current = Array.isArray(value) ? wrap(value) : value
      }
    })
  })

  runWideChecksDue = true

  // Playwright fires `networkidle` once per document, so once a page has been idle this only
  // waits the final 400 ms. A step that navigates must wait for its navigation first.
  const settle = async () => {
    await page.waitForLoadState('load').catch(() => {})
    await page.waitForLoadState('networkidle', { timeout: 3000 }).catch(() => {})
    await page.waitForTimeout(400)
  }
  const NAVIGATION_TIMEOUT = 15000
  // GTM starts after hydration. Resolves to whether the GTM stand-in started within 5 s.
  const gtmStarted = () =>
    page
      .waitForFunction(
        () => (window.dataLayer || []).some(e => e && e.event === 'stub.gtm.start'),
        null,
        { timeout: 5000 }
      )
      .then(
        () => true,
        () => false
      )
  // Reads the page. Throws "Execution context was destroyed" if a navigation replaces it mid-read.
  const state = () =>
    page.evaluate(() => ({
      url: location.href,
      h1: document.querySelector('h1')?.textContent ?? null,
      gtm: (window.dataLayer || []).some(e => e && e.event === 'stub.gtm.start')
    }))
  const H1 = { thanks: 'Thanks for buying Keybumps', license: 'Find your license key' }
  let rereads = 0
  let navigatedDuringCheck = 0
  // Expect a clean URL on `path` (with GTM on sensitive and analytics pages, none on a 404).
  // `missed` names a navigation the step waited for and never saw, which fails the check. If a
  // navigation replaces the page mid-read, read the new document the same way once it has loaded.
  // Every step's own navigation has loaded before this runs, so any navigation during it is one
  // nothing waited for: it's printed and counted.
  const expectAt = async (name, path, { h1, gtm = true, missed } = {}) => {
    const documentsBefore = documentRequests
    let s
    for (let attempt = 1; ; attempt++) {
      await settle()
      // Wait for GTM only where it belongs: a 404 is sampled after the fixed settle, so "no GTM"
      // can't pass before GTM would have started.
      if (gtm) await gtmStarted()
      try {
        s = await state()
        break
      } catch (error) {
        if (attempt === 5 || !/Execution context was destroyed/.test(error.message)) throw error
        rereads++
        console.log(
          `NOTE  ${name}: a navigation replaced the page while it was read; reading it again`
        )
        // Playwright can still hold the old document's load state here, so ask the page itself
        // (waitForFunction carries on into the new document) before settling again.
        await page
          .waitForFunction(() => document.readyState === 'complete', null, {
            timeout: NAVIGATION_TIMEOUT
          })
          .catch(() => {})
      }
    }
    if (documentRequests !== documentsBefore) {
      navigatedDuringCheck++
      console.log(`NOTE  ${name}: the page navigated while it was checked`)
    }
    const ok =
      !missed &&
      s.url === `${B}${path}` &&
      !s.url.includes('?') &&
      s.gtm === gtm &&
      (!h1 || s.h1 === h1)
    check(name, ok, missed ? { missed, ...s } : s)
  }
  // Every router call below except a lone prefetch gets a 404 for its RSC request
  // (src/lib/sensitive-url-routes.ts), so Next.js loads the URL as a new document, which then
  // redirects without its query. That load can start a second or more after the call, and for
  // the same page the URL already matches, so wait for the new document's `load` (never fired by
  // a same-document navigation). A prefetch (`loads: false`) loads nothing: wait for the
  // response to its prefetch request instead. Either one missing within the timeout fails the
  // step. Only the GTM stand-in records history changes, so it must be running before the call.
  const client = async (name, from, call, path, h1, { loads = true } = {}) => {
    await page.goto(`${B}${from}`)
    await settle()
    const watching = await gtmStarted()
    const before = pushes.length
    const wait = { timeout: NAVIGATION_TIMEOUT }
    const navigated = (
      loads
        ? page.waitForEvent('load', wait)
        : page.waitForResponse(response => {
            const headers = response.request().headers()
            return (
              !!headers.rsc &&
              !!headers['next-router-prefetch'] &&
              hasSecret(response.url()) &&
              sensitivePath(new URL(response.url()).pathname)
            )
          }, wait)
    ).then(
      () => true,
      () => false
    )
    // The navigation can replace the document before evaluate returns.
    await page.evaluate(call, Q).catch(() => {})
    const missed = (await navigated)
      ? undefined
      : `no ${loads ? 'page load' : 'prefetch response'} within ${NAVIGATION_TIMEOUT / 1000} s`
    await expectAt(name, path, { h1, missed })
    const changes = pushes.slice(before).filter(p => p.includes('gtm.historyChange-v2'))
    check(
      `${name}: no history change carries the token`,
      watching && !changes.some(hasSecret),
      watching ? changes.length : { missed: 'GTM never started on the starting page' }
    )
  }

  // A. Direct loads, as Polar returns buyers (with and without the trailing slash).
  for (const [from, path, h1] of [
    [`/thanks/?${Q}`, '/thanks/', H1.thanks],
    [`/thanks?${Q}`, '/thanks/', H1.thanks],
    [`/license/?${Q}`, '/license/', H1.license],
    [`/license?${Q}`, '/license/', H1.license],
    [`/thanks//?${Q}`, '/thanks/', H1.thanks]
  ]) {
    await page.goto(`${B}${from}`)
    await expectAt(`direct ${from.replace(Q, 'Q')}: clean URL, GTM`, path, { h1 })
  }
  const start = pushes.filter(p => p.startsWith('{"event":"stub.gtm.start"'))
  check('GTM start snapshots were recorded', start.length >= 5, start.length)

  // B. Client-side navigation inside the group (unknown route, and same page with a new query).
  await client(
    'push /thanks/ → /license/?Q',
    '/thanks/',
    q => window.next.router.push(`/license/?${q}`),
    '/license/',
    H1.license
  )
  await client(
    'push /thanks/ → /thanks/?Q (same page)',
    '/thanks/',
    q => window.next.router.push(`/thanks/?${q}`),
    '/thanks/',
    H1.thanks
  )
  await client(
    'replace /thanks/ → /thanks/?Q (same page)',
    '/thanks/',
    q => window.next.router.replace(`/thanks/?${q}`),
    '/thanks/',
    H1.thanks
  )
  await client(
    'push /license/ → /license/?Q (same page)',
    '/license/',
    q => window.next.router.push(`/license/?${q}`),
    '/license/',
    H1.license
  )
  await client(
    'replace /license/ → /license/?Q (same page)',
    '/license/',
    q => window.next.router.replace(`/license/?${q}`),
    '/license/',
    H1.license
  )
  await client(
    'push /license/ → /thanks/?Q',
    '/license/',
    q => window.next.router.push(`/thanks/?${q}`),
    '/thanks/',
    H1.thanks
  )
  await client(
    'push /thanks/ → /license?Q (no slash)',
    '/thanks/',
    q => window.next.router.push(`/license?${q}`),
    '/license/',
    H1.license
  )
  await client(
    'push /thanks/ → /license/?Q#portal',
    '/thanks/',
    q => window.next.router.push(`/license/?${q}#portal`),
    '/license/#portal',
    H1.license
  )

  // C. Prefetch, then push; and prefetch alone.
  await client(
    'prefetch then push /thanks/ → /license/?Q',
    '/thanks/',
    async q => {
      window.next.router.prefetch(`/license/?${q}`)
      await new Promise(resolve => setTimeout(resolve, 500))
      window.next.router.push(`/license/?${q}`)
    },
    '/license/',
    H1.license
  )
  await client(
    'prefetch only /license/?Q from /thanks/',
    '/thanks/',
    q => window.next.router.prefetch(`/license/?${q}`),
    '/thanks/',
    H1.thanks,
    { loads: false }
  )

  // D. From the (analytics) layout into the group.
  await client(
    'push / → /thanks/?Q',
    '/',
    q => window.next.router.push(`/thanks/?${q}`),
    '/thanks/',
    H1.thanks
  )
  await client(
    'replace /pricing/ → /thanks/?Q',
    '/pricing/',
    q => window.next.router.replace(`/thanks/?${q}`),
    '/thanks/',
    H1.thanks
  )
  await page.goto(`${B}/`)
  await settle()
  await Promise.all([
    page.waitForURL('**/license/'),
    page.locator('footer a[href="/license/"]').click()
  ])
  await expectAt('footer click / → /license/', '/license/', { h1: H1.license })

  // E. refresh() on the group's pages.
  await client(
    'refresh /thanks/',
    '/thanks/',
    () => window.next.router.refresh(),
    '/thanks/',
    H1.thanks
  )
  await client(
    'refresh /license/',
    '/license/',
    () => window.next.router.refresh(),
    '/license/',
    H1.license
  )

  // F. Back and Forward across documents and within the group.
  await page.goto(`${B}/thanks/?${Q}`)
  await expectAt('back/forward: start on /thanks/', '/thanks/', { h1: H1.thanks })
  await Promise.all([page.waitForURL(`${B}/`), page.locator('header a[href="/"]').first().click()])
  await expectAt('back/forward: click to /', '/')
  await page.goBack()
  await expectAt('back/forward: Back to /thanks/', '/thanks/', { h1: H1.thanks })
  await page.goForward()
  await expectAt('back/forward: Forward to /', '/')
  await page.goBack()
  await expectAt('back/forward: Back to /thanks/ again', '/thanks/', { h1: H1.thanks })
  await Promise.all([
    page.waitForURL('**/license/'),
    page.locator('main a[href="/license/"]').click()
  ])
  await expectAt('back/forward: /thanks/ link to /license/', '/license/', { h1: H1.license })
  await page.goBack()
  await expectAt('back/forward: Back to /thanks/ from /license/', '/thanks/', { h1: H1.thanks })
  await page.goForward()
  await expectAt('back/forward: Forward to /license/', '/license/', { h1: H1.license })
  await page.goBack()
  await expectAt('back/forward: Back to /thanks/ once more', '/thanks/', { h1: H1.thanks })

  // G. Mistyped URLs render the 404: no GTM, query stripped, then leave and come back.
  for (const path of ['/THANKS/', '/Thanks/', '/thanks/x/', '/license/x/', '/thank%73/']) {
    const response = await page.goto(`${B}${path}?${Q}`)
    await expectAt(`404 ${path}?Q: no GTM, query stripped`, path, { gtm: false })
    check(`404 ${path}?Q: status 404`, response?.status() === 404, response?.status())
  }
  await page.goto(`${B}/`)
  await settle()
  await page.goBack()
  await expectAt('404: Back to /thank%73/ stays clean', '/thank%73/', { gtm: false })
  await page.goForward()
  await expectAt('404: Forward to /', '/')

  // H. Positive control: the history-change emulation does fire on a soft navigation.
  await page.goto(`${B}/`)
  await settle()
  const beforeControl = pushes.length
  await Promise.all([
    page.waitForURL('**/pricing/'),
    page.locator('header a[href="/pricing/"]').click()
  ])
  await settle()
  check(
    'control: / → /pricing/ soft navigation records a history change',
    pushes
      .slice(beforeControl)
      .some(p => p.includes('gtm.historyChange-v2') && p.includes('/pricing/'))
  )

  // I. Page views send no RSC requests for /thanks/ or /license/ (links set prefetch={false}).
  const noiseBefore = sensitiveRsc.length
  for (const path of ['/', '/pricing/', '/support/', '/sitemap/', '/thanks/', '/license/']) {
    await page.goto(`${B}${path}`)
    await settle()
    await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight))
    await page.waitForTimeout(1500)
  }
  const noise = sensitiveRsc.slice(noiseBefore)
  check('page views prefetch nothing from /thanks/ or /license/', noise.length === 0, noise)

  runWideChecks()

  await browser.close()
  const failed = results.filter(r => !r.ok).length
  const starts = pushes.filter(p => p.startsWith('{"event":"stub.gtm.start"')).length
  console.log(
    `\n${results.length - failed} passed, ${failed} failed. ${external.length} external requests captured, ` +
      `${pushes.length} dataLayer pushes recorded, ${starts} GTM starts. ` +
      `Same-origin responses for URLs with the test values: ${tokenResponses.length} (${[...new Set(tokenResponses)].join(', ')}).` +
      ` Checks during which the page navigated: ${navigatedDuringCheck} (reads interrupted: ${rereads}).`
  )
  return failed
}

main()
  .then(failed => {
    stopPreview()
    process.exit(failed ? 1 : 0)
  })
  .catch(error => {
    console.error(error)
    if (runWideChecksDue) runWideChecks()
    stopPreview()
    process.exit(2)
  })
