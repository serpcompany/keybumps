import { describe, expect, it } from 'vitest'
import {
  iconTints,
  macPermissions,
  permissionNames,
  pluginCategories,
  pluginFor,
  plugins
} from './plugins'

describe('plugins', () => {
  it('gives each plugin a unique slug, usable as a fragment', () => {
    const slugs = plugins.map(plugin => plugin.slug)
    expect(new Set(slugs).size).toBe(slugs.length)
    for (const slug of slugs) expect(slug).toMatch(/^[a-z]+(-[a-z]+)*$/)
  })

  it('names each plugin and its capability once', () => {
    for (const key of ['name', 'capability'] as const) {
      const values = plugins.map(plugin => plugin[key])
      expect(new Set(values).size, key).toBe(values.length)
    }
  })

  it('lists every plugin in one of the three Store categories', () => {
    expect(pluginCategories).toEqual(['Productivity', 'Writing', 'Media'])
    for (const plugin of plugins) expect(pluginCategories, plugin.slug).toContain(plugin.category)
  })

  it('uses only known tints and permissions', () => {
    for (const plugin of plugins) {
      expect(Object.keys(iconTints), plugin.slug).toContain(plugin.tint)
      for (const permission of plugin.permissions) {
        expect(macPermissions, plugin.slug).toContain(permission)
      }
    }
  })

  it('selects each palette tab with its own Command-number', () => {
    const keys = plugins.flatMap(plugin =>
      plugin.paletteTab ? [plugin.paletteTab.commandKey] : []
    )
    expect(new Set(keys).size).toBe(keys.length)
  })

  it('requires only listed plugins', () => {
    for (const plugin of plugins) {
      for (const slug of plugin.requires) expect(() => pluginFor(slug), plugin.slug).not.toThrow()
    }
  })

  it('keeps the seven default capabilities apart from the added ones, and marks only added ones new', () => {
    expect(plugins.filter(plugin => plugin.isDefault).map(plugin => plugin.name)).toEqual([
      'Quick Search',
      'Clipboard History',
      'Screenshot Tools',
      'Dictation',
      'Window Manager',
      'Shortcut Coach',
      'Snippets'
    ])
    for (const plugin of plugins) {
      if (plugin.isNew) expect(plugin.isDefault, plugin.slug).toBe(false)
    }
  })

  it('writes permission lists as the app does', () => {
    expect(permissionNames([])).toBe('')
    expect(permissionNames(['Accessibility'])).toBe('Accessibility')
    expect(permissionNames(['Speech Recognition', 'Microphone'])).toBe(
      'Microphone and Speech Recognition'
    )
    expect(permissionNames(['Speech Recognition', 'Accessibility', 'Microphone'])).toBe(
      'Accessibility, Microphone, and Speech Recognition'
    )
  })
})
