import { existsSync, readdirSync, readFileSync, realpathSync } from 'node:fs'
import { join, relative, sep } from 'node:path'
import ts from 'typescript'
import { describe, expect, it } from 'vitest'
import { isSensitiveUrlPath, sensitiveUrlPaths } from './pages'

const srcDir = realpathSync.native(join(__dirname, '..'))
const webDir = join(srcDir, '..')
const appDir = join(srcDir, 'app')
const analyticsGroup = '(analytics)'
const sensitiveGroup = '(sensitive-url)'
const analyticsComponent = join(srcDir, 'components', 'analytics.tsx')
const siteDocument = join(srcDir, 'components', 'site-document.tsx')
const footer = join(srcDir, 'components', 'site-footer.tsx')
const rootLayouts = [
  join(appDir, analyticsGroup, 'layout.tsx'),
  join(appDir, sensitiveGroup, 'layout.tsx')
]
/** Documents whose URLs can carry checkout or session data: they strip the query in <head>. */
const strippingDocuments = [
  join(appDir, sensitiveGroup, 'layout.tsx'),
  join(appDir, 'global-not-found.tsx')
]
const sourceExtensions = ['.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs']

const compilerOptions = ts.parseJsonConfigFileContent(
  ts.readConfigFile(join(webDir, 'tsconfig.json'), ts.sys.readFile).config,
  ts.sys,
  webDir
).options

function files(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const full = join(dir, entry.name)
    return entry.isDirectory() ? files(full) : [full]
  })
}

/** Source files under src/, without tests. */
function sourceFiles() {
  return files(srcDir).filter(
    file => sourceExtensions.some(ext => file.endsWith(ext)) && !/\.test\.ts$/.test(file)
  )
}

/**
 * Every module specifier in a file, as TypeScript's own scanner reads them: imports, export-from,
 * side-effect imports, `import()` (template literals and magic comments too), and `require()`.
 */
function importSpecifiers(source: string) {
  return ts.preProcessFile(source, true, true).importedFiles.map(file => file.fileName)
}

/**
 * Resolves a specifier the way the project does (tsconfig `paths`, bundler resolution) to a file
 * under src/, with its real on-disk path and case, or null for a package or an unresolved path.
 */
function resolveImport(fromFile: string, specifier: string) {
  const resolved = ts.resolveModuleName(specifier, fromFile, compilerOptions, ts.sys).resolvedModule
  if (!resolved || resolved.isExternalLibraryImport) return null
  const file = realpathSync.native(resolved.resolvedFileName)
  return file.startsWith(srcDir + sep) ? file : null
}

// Other analytics tools, matched by module or name: @next/third-parties (GoogleTagManager,
// GoogleAnalytics, and the rest), gtag, and the Cloudflare beacon. <Analytics is the component.
const markers = [
  /['"]@next\/third-parties/,
  /<Analytics\b/,
  /GoogleTagManager|GoogleAnalytics/,
  /googletagmanager|google-analytics|gtag\(/i,
  /cloudflareinsights/i
]

/**
 * Source files that load analytics: they mention another analytics tool, or they reach
 * components/analytics.tsx through any chain of imports. So a file that imports a root layout, or
 * a component that imports the analytics component, counts too. `overrides` replaces a file's
 * source, for testing injected imports.
 */
function analyticsFiles(overrides: Record<string, string> = {}) {
  const sources = new Map(
    sourceFiles().map(file => [file, overrides[file] ?? readFileSync(file, 'utf8')])
  )
  const imports = new Map(
    [...sources].map(([file, source]) => [
      file,
      importSpecifiers(source).flatMap(specifier => resolveImport(file, specifier) ?? [])
    ])
  )
  const reaches = (file: string, seen = new Set<string>()): boolean => {
    if (file === analyticsComponent) return true
    if (seen.has(file)) return false
    seen.add(file)
    return (imports.get(file) ?? []).some(next => reaches(next, seen))
  }
  return [...sources]
    .filter(([file, source]) => reaches(file) || markers.some(marker => marker.test(source)))
    .map(([file]) => relative(srcDir, file))
    .sort()
}

function parse(file: string, source = readFileSync(file, 'utf8')) {
  return ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
}

/** A URL string that starts with a sensitive-url page path, in any case or slash form. */
const sensitivePrefix = new RegExp(
  `^(?:${sensitiveUrlPaths.map(path => path.replace(/\/$/, '')).join('|')})(?:/|\\?|#|$)`,
  'i'
)

/**
 * Every place a source file builds a URL for a sensitive-url page that has, or may get, a query:
 * a string with `?`, a template or `+` concatenation that starts with the page path, and a
 * `{ pathname, query }` or `{ pathname, search }` object. GTM's click triggers push a clicked
 * link's `href` as `gtm.elementUrl`, so no link may carry one.
 */
function sensitiveQueryLinks(sourceFile: ts.SourceFile) {
  const found: string[] = []
  const isPlus = (node: ts.Node): node is ts.BinaryExpression =>
    ts.isBinaryExpression(node) && node.operatorToken.kind === ts.SyntaxKind.PlusToken
  const staticText = (node: ts.Node | undefined) => {
    let expression = node
    while (expression && ts.isParenthesizedExpression(expression))
      expression = expression.expression
    if (!expression) return null
    if (ts.isStringLiteralLike(expression)) return expression.text
    if (ts.isTemplateExpression(expression)) return expression.head.text
    return null
  }
  const propertyName = (property: ts.ObjectLiteralElementLike) =>
    property.name ? property.name.getText().replace(/['"]/g, '') : null
  const visit = (node: ts.Node) => {
    if (
      ts.isStringLiteralLike(node) &&
      node.text.includes('?') &&
      sensitivePrefix.test(node.text)
    ) {
      found.push(node.getText())
    } else if (ts.isTemplateExpression(node) && sensitivePrefix.test(node.head.text)) {
      found.push(node.getText())
    } else if (isPlus(node) && !isPlus(node.parent)) {
      let left: ts.Expression = node
      while (isPlus(left)) left = left.left
      const first = staticText(left)
      if (first !== null && sensitivePrefix.test(first)) found.push(node.getText())
    } else if (ts.isObjectLiteralExpression(node)) {
      const names = new Set(node.properties.map(propertyName))
      const pathname = node.properties.find(
        (property): property is ts.PropertyAssignment =>
          ts.isPropertyAssignment(property) && propertyName(property) === 'pathname'
      )
      const text = staticText(pathname?.initializer)
      if (
        text !== null &&
        sensitivePrefix.test(text) &&
        (names.has('query') || names.has('search'))
      ) {
        found.push(node.getText())
      }
    }
    ts.forEachChild(node, visit)
  }
  visit(sourceFile)
  return found
}

/** Every JSX element in a file, as [tag name, node]. Comments are not elements. */
function jsxElements(file: string) {
  const sourceFile = parse(file)
  const elements: { tag: string; node: ts.JsxSelfClosingElement | ts.JsxElement }[] = []
  const visit = (node: ts.Node) => {
    if (ts.isJsxSelfClosingElement(node)) elements.push({ tag: node.tagName.getText(), node })
    if (ts.isJsxElement(node)) elements.push({ tag: node.openingElement.tagName.getText(), node })
    ts.forEachChild(node, visit)
  }
  visit(sourceFile)
  return elements
}

function attributes(node: ts.JsxSelfClosingElement | ts.JsxElement) {
  return ts.isJsxElement(node) ? node.openingElement.attributes : node.attributes
}

/** JSX children that render something: no whitespace-only text, no `{/* comment *\/}`. */
function jsxChildren(node: ts.JsxElement) {
  return node.children.filter(child =>
    ts.isJsxText(child)
      ? child.getText().trim() !== ''
      : !ts.isJsxExpression(child) || child.expression !== undefined
  )
}

/** Every page.tsx under src/app, with the URL it serves and its top-level route group. */
function appPages() {
  return files(appDir)
    .filter(file => file.endsWith(`${sep}page.tsx`))
    .map(file => {
      const segments = relative(appDir, file).split(sep).slice(0, -1)
      const routeSegments = segments.filter(segment => !/^\(.*\)$/.test(segment))
      return {
        url: routeSegments.length ? `/${routeSegments.join('/')}/` : '/',
        group: segments[0]
      }
    })
}

describe('analytics scope', () => {
  it('has two separate root layouts and no shared one, so crossing between them reloads', () => {
    expect(existsSync(join(appDir, 'layout.tsx'))).toBe(false)
    const layouts = files(appDir).filter(file => file.endsWith(`${sep}layout.tsx`))
    expect(layouts.sort()).toEqual([...rootLayouts].sort())
    for (const layout of layouts) {
      // Each renders its own <html> and <body> through SiteDocument.
      const tags = jsxElements(layout).map(element => element.tag)
      expect(tags, relative(srcDir, layout)).toContain('SiteDocument')
    }
    expect(jsxElements(siteDocument).map(element => element.tag)).toContain('html')
  })

  it('loads analytics only from the analytics component and the two root layouts', () => {
    const allowed = [analyticsComponent, ...rootLayouts].map(file => relative(srcDir, file)).sort()
    expect(analyticsFiles()).toEqual(allowed)
  })

  it('catches every form of import of the analytics component or a root layout', () => {
    const original = readFileSync(footer, 'utf8')
    const injections = [
      "import { Analytics as Tracking } from './analytics'",
      "import {\n  // don't rename this\n  Analytics as Tracking\n} from './analytics'",
      'import {\n  // the "real" one\n  Analytics as Tracking\n} from \'./analytics\'',
      "export { Analytics } from '../components/analytics.tsx'",
      "export * from './analytics'",
      "import './analytics'",
      "const Lazy = dynamic(() => import('@/components/analytics'))",
      'const Lazy = dynamic(() => import(`./analytics`).then(m => m.Analytics))',
      "const Lazy = import(/* webpackChunkName: 'x' */ './analytics')",
      "const Old = require('./analytics')",
      "import Layout from '@/app/(analytics)/layout'",
      "export { default } from '../app/(sensitive-url)/layout'",
      "import { GoogleAnalytics } from '@next/third-parties/google'"
    ]
    // A case variant resolves only on a case-insensitive file system, such as macOS; the build
    // fails on Linux CI anyway.
    if (existsSync(join(srcDir, 'components', 'Analytics.tsx'))) {
      injections.push("import { Analytics as Tracking } from './Analytics'")
    }
    for (const injection of injections) {
      const found = analyticsFiles({ [footer]: `${injection}\n${original}` })
      expect(found, injection).toContain(join('components', 'site-footer.tsx'))
    }
    expect(resolveImport(footer, '@next/third-parties/google')).toBeNull()
  })

  it('strips the query in <head>, before <body>, on documents for sensitive URLs', () => {
    for (const file of strippingDocuments) {
      // <SiteDocument head={<StripQuery />}>, as elements: a commented-out one doesn't count.
      const heads = jsxElements(file)
        .filter(element => element.tag === 'SiteDocument')
        .flatMap(element => attributes(element.node).properties)
        .filter(ts.isJsxAttribute)
        .filter(attribute => attribute.name.getText() === 'head')
        .map(attribute => attribute.initializer)
      expect(heads, relative(srcDir, file)).toHaveLength(1)
      const [head] = heads
      const element = head && ts.isJsxExpression(head) ? head.expression : undefined
      expect(
        element && ts.isJsxSelfClosingElement(element) && element.tagName.getText(),
        relative(srcDir, file)
      ).toBe('StripQuery')
    }
    // SiteDocument renders `head` as the only source content of <head>, the first child of <html>,
    // so it runs before the browser parses <body>. This checks source order: in the rendered HTML,
    // React and Next.js hoist stylesheets, scripts, preloads, and metadata above it.
    const html = jsxElements(siteDocument).find(element => element.tag === 'html')?.node
    expect(html && ts.isJsxElement(html)).toBe(true)
    const [first] = html && ts.isJsxElement(html) ? jsxChildren(html) : []
    expect(first && ts.isJsxElement(first) && first.openingElement.tagName.getText()).toBe('head')
    const headChildren = first && ts.isJsxElement(first) ? jsxChildren(first) : []
    expect(headChildren.map(child => child.getText())).toEqual(['{head}'])
  })

  it('rewrites every RSC request for a sensitive-url page to a 404 (a full page load)', () => {
    // next.config.ts rewrites every RSC request for them to a 404 (sensitiveUrlRewrites), so a
    // <Link>, router.push(), or prefetch to them, with or without a query, becomes a document
    // request that the page redirects. src/lib/sensitive-url-routes.test.ts checks the matching.
    const config = ts.createSourceFile(
      'next.config.ts',
      readFileSync(join(webDir, 'next.config.ts'), 'utf8'),
      ts.ScriptTarget.Latest,
      true
    )
    const beforeFiles: string[] = []
    const visit = (node: ts.Node) => {
      if (ts.isPropertyAssignment(node) && node.name.getText() === 'beforeFiles') {
        beforeFiles.push(node.initializer.getText())
      }
      ts.forEachChild(node, visit)
    }
    visit(config)
    expect(beforeFiles).toEqual(['sensitiveUrlRewrites()'])
  })

  it('never links to a sensitive-url page with a query, in any form', () => {
    const found = sourceFiles().flatMap(file =>
      sensitiveQueryLinks(parse(file)).map(text => `${relative(srcDir, file)}: ${text}`)
    )
    expect(found).toEqual([])
  })

  it('catches string, template, concatenation, and object forms of a link with a query', () => {
    const original = readFileSync(footer, 'utf8')
    const probe = (expression: string) =>
      `${original}\nexport const probe = () => (${expression})\n`
    const injections = [
      '<Link href="/license/?ref=x">Key</Link>',
      // biome-ignore lint/suspicious/noTemplateCurlyInString: source text for the parser.
      '<Link href={`/license/?ref=${ref}`}>Key</Link>',
      // biome-ignore lint/suspicious/noTemplateCurlyInString: source text for the parser.
      '<Link href={`/thanks/${search}`}>Thanks</Link>',
      "<Link href={'/license/' + '?ref=x'}>Key</Link>",
      "<Link href={('/license/' + search)}>Key</Link>",
      "<Link href={{ pathname: '/license/', query: { ref: 'x' } }}>Key</Link>",
      "<Link href={{ pathname: '/thanks/', search }}>Thanks</Link>",
      "router.push('/thanks?ref=x')",
      "new URL('/LICENSE/?ref=x', location.href)"
    ]
    for (const injection of injections) {
      expect(sensitiveQueryLinks(parse(footer, probe(injection))), injection).not.toEqual([])
    }
    for (const allowed of [
      '<Link href="/license/" prefetch={false}>Key</Link>',
      "<a href='/thanks/#activate'>Activate</a>",
      "<Link href={{ pathname: '/pricing/', query: { ref: 'x' } }}>Pricing</Link>"
    ]) {
      expect(sensitiveQueryLinks(parse(footer, probe(allowed))), allowed).toEqual([])
    }
  })

  it('never prefetches a sensitive-url page, whose RSC requests 404 by design', () => {
    for (const file of sourceFiles().filter(file => file.endsWith('.tsx'))) {
      for (const link of jsxElements(file).filter(element => element.tag === 'Link')) {
        const props = attributes(link.node).properties.filter(ts.isJsxAttribute)
        const prop = (name: string) => props.find(attribute => attribute.name.getText() === name)
        const href = prop('href')?.initializer
        const inner = href && ts.isJsxExpression(href) ? href.expression : href
        const prefetch = prop('prefetch')?.initializer?.getText()
        const where = `${relative(srcDir, file)}: ${link.node.getText().split('\n')[0]}`
        if (inner && ts.isStringLiteralLike(inner)) {
          if (isSensitiveUrlPath(inner.text.split(/[?#]/)[0]))
            expect(prefetch, where).toBe('{false}')
        } else {
          // A computed href must decide explicitly, with linkPrefetch() from src/lib/pages.ts.
          expect(prefetch, where).toMatch(/^\{linkPrefetch\(/)
        }
      }
    }
  })

  it('keeps anything that could stream or cache the page above its redirect out of the group', () => {
    // A loading.tsx (or a Suspense boundary above the page) makes the page stream, and redirect()
    // then becomes a 200 with a meta refresh and the query in the RSC payload. Segment config
    // (dynamic = 'force-static', revalidate, …) or generateStaticParams can serve the page without
    // running it. So the group holds only its layout and its two pages.
    const group = join(appDir, sensitiveGroup)
    expect(
      files(group)
        .map(file => relative(group, file))
        .sort()
    ).toEqual(
      [
        'layout.tsx',
        ...sensitiveUrlPaths.map(path => join(...path.split('/').filter(Boolean), 'page.tsx'))
      ].sort()
    )
    const segmentConfig =
      /export\s+(?:const|let|var|async\s+function|function)\s+(?:dynamic|dynamicParams|revalidate|fetchCache|runtime|preferredRegion|maxDuration|experimental_ppr|generateStaticParams|unstable_\w+)\b/
    for (const file of [...files(group), siteDocument]) {
      const source = readFileSync(file, 'utf8')
      expect(source, relative(srcDir, file)).not.toMatch(/\bSuspense\b/)
      expect(source, relative(srcDir, file)).not.toMatch(segmentConfig)
    }
    // Site-wide switches that change how every page renders and streams.
    expect(readFileSync(join(webDir, 'next.config.ts'), 'utf8')).not.toMatch(
      /\b(?:cacheComponents|ppr|dynamicIO)\b/
    )
  })

  it('redirects every sensitive-url page to its bare URL before it renders', () => {
    for (const path of sensitiveUrlPaths) {
      const file = join(appDir, sensitiveGroup, ...path.split('/').filter(Boolean), 'page.tsx')
      const sourceFile = ts.createSourceFile(
        file,
        readFileSync(file, 'utf8'),
        ts.ScriptTarget.Latest,
        true,
        ts.ScriptKind.TSX
      )
      const page = sourceFile.statements
        .filter(ts.isFunctionDeclaration)
        .find(fn => fn.modifiers?.some(m => m.kind === ts.SyntaxKind.DefaultKeyword))
      const [first] = page?.body?.statements ?? []
      expect(first?.getText(), path).toBe(`await redirectWithoutQuery('${path}', searchParams)`)
    }
  })

  it('serves pages whose URLs carry checkout, session, or license data from the sensitive-url layout', () => {
    const pages = appPages()
    for (const path of sensitiveUrlPaths) {
      const page = pages.find(candidate => candidate.url === path)
      expect(page, path).toBeDefined()
      expect(page?.group, path).toBe(sensitiveGroup)
    }
  })

  it('serves every other page from the analytics layout', () => {
    const sensitive: readonly string[] = sensitiveUrlPaths
    for (const page of appPages()) {
      expect(page.group, page.url).toBe(
        sensitive.includes(page.url) ? sensitiveGroup : analyticsGroup
      )
    }
  })
})
