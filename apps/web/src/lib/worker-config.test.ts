import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import { experimental_readRawConfig, unstable_readConfig } from 'wrangler'

const config = fileURLToPath(new URL('../../wrangler.jsonc', import.meta.url))

// Every environment in wrangler.jsonc, plus the top level (local runs), resolved the way Wrangler
// resolves it for a deploy, including inheritance from the top level.
const envNames = Object.keys(experimental_readRawConfig({ config }).rawConfig.env ?? {})
const environments = [undefined, ...envNames]

describe('wrangler.jsonc', () => {
  it('has the staging and production environments', () => {
    expect(envNames).toEqual(expect.arrayContaining(['staging', 'production']))
  })

  // Workers Logs record the request URL. /thanks/ receives Polar's customer-session token in the
  // query string, so no environment may log query strings.
  it.each(environments)('redacts query strings from Workers Logs (env: %s)', env => {
    const { observability } = unstable_readConfig({ config, env })
    expect(observability?.enabled).toBe(true)
    expect(observability?.redact_query_string).toBe(true)
  })

  it.each(envNames)('sets SITE_ENV at runtime and names its own Worker (env: %s)', env => {
    const resolved = unstable_readConfig({ config, env })
    expect(resolved.name).toBe(`keybumps-web-${env}`)
    expect(resolved.vars.SITE_ENV).toBe(env)
    expect(resolved.services).toContainEqual({
      binding: 'WORKER_SELF_REFERENCE',
      service: `keybumps-web-${env}`
    })
  })
})
