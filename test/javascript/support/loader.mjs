// Resolve hook for running the ESM app sources under Node's built-in test
// runner. The browser bundle is built with esbuild, which resolves
// extensionless relative imports (e.g. `import ... from './helper'`). Native
// Node ESM requires an explicit extension, so this hook appends `.js` to any
// relative specifier that would otherwise fail to resolve. This lets the tests
// exercise the real app source (app/javascript/*.js) without a bundling step.
import { extname } from 'node:path'

export async function resolve (specifier, context, nextResolve) {
  try {
    return await nextResolve(specifier, context)
  } catch (error) {
    const isRelative = specifier.startsWith('./') || specifier.startsWith('../')

    if (isRelative && extname(specifier) === '') {
      return nextResolve(`${specifier}.js`, context)
    }

    throw error
  }
}
