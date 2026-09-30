import { afterEach, describe, expect, it } from 'vitest'
import { replaceUrlKeepingRouterState, strippedUrl } from './strip-query'

type Call = { data: unknown; url: string }

/** A stand-in for the browser's History, whose replaceState lives on the prototype. */
class FakeHistory {
  state: unknown = { __NA: true, __PRIVATE_NEXTJS_INTERNALS_TREE: ['tree'] }
  calls: Call[] = []
  replaceState(data: unknown, _unused: string, url: string) {
    this.calls.push({ data, url })
    this.state = data
  }
}

const globals = globalThis as { History?: unknown }
const originalHistory = globals.History

afterEach(() => {
  globals.History = originalHistory
})

describe('StripQuery', () => {
  it('keeps the path and hash and drops the query', () => {
    expect(strippedUrl({ pathname: '/thanks/', hash: '' })).toBe('/thanks/')
    expect(strippedUrl({ pathname: '/license/', hash: '#portal' })).toBe('/license/#portal')
  })

  it('passes the router state through when the App Router has not patched history yet', () => {
    globals.History = FakeHistory
    const history = new FakeHistory()
    const routerState = history.state
    replaceUrlKeepingRouterState(history as unknown as History, '/thanks/')
    expect(history.calls).toEqual([{ data: routerState, url: '/thanks/' }])
    expect(history.state).not.toBeNull()
  })

  it('lets the patched replaceState copy the router state once the App Router has patched it', () => {
    globals.History = FakeHistory
    const history = new FakeHistory()
    const routerState = history.state
    const received: unknown[] = []
    // Next.js assigns its patch as an own property of window.history.
    history.replaceState = (data, _unused, url) => {
      received.push(data)
      FakeHistory.prototype.replaceState.call(history, data ?? routerState, _unused, url)
    }
    replaceUrlKeepingRouterState(history as unknown as History, '/thanks/')
    expect(received).toEqual([null])
    expect(history.state).toEqual(routerState)
  })
})
