import { defineConfig } from 'tsdown'

/**
 * Standalone tsdown config for the dsh-pet plugin — host half
 * only. Bundles src/index.ts into lib/index.js (ESM); the cordis framework
 * resolves at runtime from the dsh profile tree, never from this repo's
 * install, so it stays external.
 */
export default defineConfig({
  name: '@sundusk/dsh-pet',
  entry: ['src/index.ts'],
  outDir: 'lib',
  format: ['esm'],
  platform: 'node',
  target: 'es2024',
  fixedExtension: false,
  dts: false,
  clean: false,
  deps: { neverBundle: ['@deepseek-ai/cordis', /^@deepseek-ai\//] },
})
