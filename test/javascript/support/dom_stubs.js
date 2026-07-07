// Minimal browser-environment stubs so the Web_Player source (which imports
// `howler` and touches `window` / `document` / `localStorage`) can be loaded
// and exercised under Node's built-in test runner without a full DOM.
//
// This module MUST be imported before app/javascript/player.js: the `howler`
// import at the top of player.js reads `window` during module evaluation, and
// ESM evaluates imports in source order, so listing this import first
// guarantees the stubs exist in time.

// A small in-memory Local_Position_Store standing in for window.localStorage.
class FakeStorage {
  #store = new Map()

  getItem (key) {
    return this.#store.has(key) ? this.#store.get(key) : null
  }

  setItem (key, value) {
    this.#store.set(key, String(value))
  }

  removeItem (key) {
    this.#store.delete(key)
  }

  clear () {
    this.#store.clear()
  }
}

const localStorage = new FakeStorage()

// document.querySelector is configurable so the readConstants test can present
// a fake [data-playback-constants] element; by default nothing is present, so
// PositionSync falls back to its mirrored defaults.
let constantsElement = null

function setConstantsElement (dataset) {
  constantsElement = dataset ? { dataset } : null
}

const documentStub = {
  querySelector (selector) {
    if (selector === '[data-playback-constants]') { return constantsElement }
    return null
  }
}

// howler checks `typeof window !== 'undefined'`; point window at the global.
globalThis.window = globalThis
globalThis.localStorage = localStorage
globalThis.window.localStorage = localStorage
globalThis.document = documentStub

export { localStorage, setConstantsElement }
