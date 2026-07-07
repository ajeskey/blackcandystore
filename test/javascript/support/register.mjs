// Registers the resolve hook (loader.mjs) so the app's extensionless relative
// ESM imports resolve under Node's built-in test runner. Loaded via
// `node --import ./test/javascript/support/register.mjs`.
import { register } from 'node:module'

register('./loader.mjs', import.meta.url)
