import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { StripQuery, stripQueryScript } from './strip-query'

type Call = { data: unknown; url: string }

/** Runs the inline script against a fake window. The query values are obvious placeholders. */
function run(href: string, options: { replaceStateThrows?: boolean } = {}) {
  const url = new URL(href)
  const calls: Call[] = []
  const replaced: string[] = []
  let stopped = false
  const state = { __NA: true, __PRIVATE_NEXTJS_INTERNALS_TREE: ['tree'] }
  const window = {
    location: {
      search: url.search,
      pathname: url.pathname,
      hash: url.hash,
      replace: (to: string) => replaced.push(to)
    },
    history: {
      state,
      replaceState(data: unknown, _unused: string, to: string) {
        if (options.replaceStateThrows) throw new Error('SecurityError')
        calls.push({ data, url: to })
      }
    },
    stop: () => {
      stopped = true
    }
  }
  new Function('window', stripQueryScript)(window)
  return { calls, replaced, stopped, state }
}

describe('StripQuery', () => {
  it('replaces the URL with its path and hash, passing the history state through', () => {
    const result = run('https://keybumps.app/thanks/?checkout_id=fake&customer_session_token=FAKE')
    expect(result.calls).toEqual([{ data: result.state, url: '/thanks/' }])
    expect(run('https://keybumps.app/license/?x=FAKE#portal').calls).toEqual([
      { data: result.state, url: '/license/#portal' }
    ])
  })

  it('leaves a URL without a query alone', () => {
    const result = run('https://keybumps.app/thanks/#top')
    expect(result.calls).toEqual([])
    expect(result.replaced).toEqual([])
  })

  it('fails closed: stops parsing and reloads without the query if it cannot replace the URL', () => {
    const result = run('https://keybumps.app/thanks/?customer_session_token=FAKE', {
      replaceStateThrows: true
    })
    expect(result.stopped).toBe(true)
    expect(result.replaced).toEqual(['/thanks/'])
  })

  it('renders the script inline, so it runs before the parser continues', () => {
    const html = renderToStaticMarkup(StripQuery())
    expect(html).toBe(`<script>${stripQueryScript}</script>`)
  })
})
