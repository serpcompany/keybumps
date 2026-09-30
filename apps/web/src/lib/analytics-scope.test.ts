import { existsSync, readdirSync, readFileSync, realpathSync } from 'node:fs'
import { join, relative, sep } from 'node:path'
import ts from 'typescript'
import { describe, expect, it } from 'vitest'
import { sensitiveUrlPaths } from './pages'

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

/** Every JSX element in a file, as [tag name, node]. Comments are not elements. */
function jsxElements(file: string) {
  const sourceFile = ts.createSourceFile(
    file,
    readFileSync(file, 'utf8'),
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TSX
  )
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

/** Every string a source file spells out: string literals and template literal text. */
function stringLiterals(file: string) {
  const sourceFile = ts.createSourceFile(
    file,
    readFileSync(file, 'utf8'),
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TSX
  )
  const strings: string[] = []
  const visit = (node: ts.Node) => {
    if (ts.isStringLiteralLike(node) || ts.isTemplateHead(node)) strings.push(node.text)
    ts.forEachChild(node, visit)
  }
  visit(sourceFile)
  return strings
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

  it('strips the query in <head> before anything else runs on documents for sensitive URLs', () => {
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
    // SiteDocument renders `head` as the only content of <head>, the first child of <html>.
    const html = jsxElements(siteDocument).find(element => element.tag === 'html')?.node
    expect(html && ts.isJsxElement(html)).toBe(true)
    const [first] = html && ts.isJsxElement(html) ? jsxChildren(html) : []
    expect(first && ts.isJsxElement(first) && first.openingElement.tagName.getText()).toBe('head')
    const headChildren = first && ts.isJsxElement(first) ? jsxChildren(first) : []
    expect(headChildren.map(child => child.getText())).toEqual(['{head}'])
  })

  it('never links to a sensitive URL with a query, which a soft navigation would show to GTM', () => {
    const prefixes = sensitiveUrlPaths.map(path => path.replace(/\/$/, ''))
    const found = sourceFiles().flatMap(file =>
      stringLiterals(file)
        .filter(text =>
          prefixes.some(prefix => new RegExp(`^${prefix}/?\\?`, 'i').test(text.trim()))
        )
        .map(text => `${relative(srcDir, file)}: ${text}`)
    )
    expect(found).toEqual([])
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
