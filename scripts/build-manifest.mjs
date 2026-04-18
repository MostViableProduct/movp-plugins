#!/usr/bin/env node
import { readdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'

const root = process.cwd()

// Version: first "## X.Y.Z" heading in CHANGELOG.md
const changelog = readFileSync(join(root, 'CHANGELOG.md'), 'utf8')
const versionMatch = changelog.match(/^## ([0-9]+\.[0-9]+\.[0-9]+)(?:\s|$)/m)
const version = versionMatch?.[1] ?? '0.0.0'

function listDirEntries(p, { filesOnly = false, dirsOnly = false } = {}) {
  const abs = join(root, p)
  if (!existsSync(abs)) return []
  return readdirSync(abs, { withFileTypes: true })
    .filter((e) => !e.name.startsWith('.'))
    .filter((e) => (filesOnly ? e.isFile() : dirsOnly ? e.isDirectory() : true))
    .map((e) => e.name)
    .sort()
}

function commandsFor(plugin) {
  return listDirEntries(`${plugin}/commands`, { filesOnly: true })
    .filter((n) => n.endsWith('.md'))
    .map((n) => `/movp:${n.replace(/\.md$/, '')}`)
}

function skillsFor(plugin) {
  return listDirEntries(`${plugin}/skills`, { dirsOnly: true })
}

/**
 * Hooks live in `<plugin>/hooks/hooks.json`. Each wired hook's `command`
 * field ends with the canonical hook name (the last whitespace-separated
 * token). Extract and de-duplicate them across all hook groups.
 */
function hooksFor(plugin) {
  const hooksFile = join(root, plugin, 'hooks/hooks.json')
  if (!existsSync(hooksFile)) return []
  const doc = JSON.parse(readFileSync(hooksFile, 'utf8'))
  const names = new Set()
  for (const group of Object.values(doc.hooks ?? {})) {
    for (const matcher of group ?? []) {
      for (const h of matcher.hooks ?? []) {
        if (typeof h.command !== 'string') continue
        // Last whitespace-separated token is the canonical hook name.
        const tokens = h.command.trim().split(/\s+/)
        const last = tokens[tokens.length - 1]?.replace(/^"|"$/g, '')
        if (last) names.add(last)
      }
    }
  }
  return [...names].sort()
}

const manifest = {
  version,
  tools: {
    claude: {
      commands: commandsFor('claude-plugin'),
      skills: skillsFor('claude-plugin'),
      hooks: hooksFor('claude-plugin'),
    },
    cursor: {
      commands: commandsFor('cursor-plugin'),
      skills: skillsFor('cursor-plugin'),
      hooks: hooksFor('cursor-plugin'),
    },
    codex: {
      commands: commandsFor('codex-plugin'),
      skills: skillsFor('codex-plugin'),
      hooks: hooksFor('codex-plugin'),
    },
  },
}

writeFileSync(join(root, 'plugin-manifest.json'), JSON.stringify(manifest, null, 2) + '\n')
console.log(`Wrote plugin-manifest.json (version ${version})`)
