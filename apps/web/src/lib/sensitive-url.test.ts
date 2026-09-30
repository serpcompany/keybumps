import { beforeEach, describe, expect, it, vi } from 'vitest'
import { redirectWithoutQuery } from './sensitive-url'

const redirect = vi.hoisted(() =>
  vi.fn((path: string) => {
    throw new Error(`NEXT_REDIRECT ${path}`)
  })
)
vi.mock('next/navigation', () => ({ redirect }))

beforeEach(() => {
  redirect.mockClear()
})

describe('redirectWithoutQuery', () => {
  it('redirects to the bare page when the request has any query parameter', async () => {
    // Obvious placeholders, never real values.
    const searchParams = Promise.resolve({ checkout_id: 'fake', customer_session_token: 'FAKE' })
    await expect(redirectWithoutQuery('/thanks/', searchParams)).rejects.toThrow(
      'NEXT_REDIRECT /thanks/'
    )
    await expect(redirectWithoutQuery('/license/', Promise.resolve({ x: '' }))).rejects.toThrow(
      'NEXT_REDIRECT /license/'
    )
    expect(redirect.mock.calls).toEqual([['/thanks/'], ['/license/']])
  })

  it('renders the page when there is no query', async () => {
    await expect(redirectWithoutQuery('/thanks/', Promise.resolve({}))).resolves.toBeUndefined()
    expect(redirect).not.toHaveBeenCalled()
  })
})
