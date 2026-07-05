import { Controller } from '@hotwired/stimulus'

// Copies the value of a source element to the clipboard and briefly confirms.
//
//   <div data-controller="clipboard" data-clipboard-success-message-value="Copied">
//     <input data-clipboard-target="source" ...>
//     <button data-clipboard-target="button" data-action="clipboard#copy">Copy</button>
//   </div>
export default class extends Controller {
  static targets = ['source', 'button']
  static values = { successMessage: { type: String, default: 'Copied' } }

  async copy (event) {
    event?.preventDefault()

    const text = this.#sourceText()
    if (!text) return

    try {
      await navigator.clipboard.writeText(text)
    } catch {
      // Fallback for insecure contexts / browsers without the async clipboard API.
      if (this.sourceTarget.select) {
        this.sourceTarget.select()
        document.execCommand('copy')
      }
    }

    this.#confirm()
  }

  #sourceText () {
    if (!this.hasSourceTarget) return ''
    return this.sourceTarget.value ?? this.sourceTarget.textContent ?? ''
  }

  #confirm () {
    if (!this.hasButtonTarget) return

    const original = this.buttonTarget.textContent
    this.buttonTarget.textContent = this.successMessageValue
    setTimeout(() => { this.buttonTarget.textContent = original }, 1500)
  }
}
