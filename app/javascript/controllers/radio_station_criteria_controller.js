import { Controller } from '@hotwired/stimulus'

// Drives the Radio_Station source-criteria builder (Req 1.2): add or remove
// Station_Source_Criteria rows and, within a row, reveal only the value input
// relevant to the selected criterion type (artist / song / genre). Each row is
// rendered from the same `_criterion_fields` partial, so a new row is cloned
// from a hidden <template> and appended to the rows container.
//
//   <div data-controller="radio-station-criteria">
//     <div data-radio-station-criteria-target="rows">...</div>
//     <template data-radio-station-criteria-target="template">...</template>
//     <button data-action="radio-station-criteria#addRow">Add</button>
//   </div>
export default class extends Controller {
  static targets = ['rows', 'template']

  addRow () {
    if (!this.hasTemplateTarget || !this.hasRowsTarget) { return }

    const fragment = this.templateTarget.content.cloneNode(true)
    this.rowsTarget.appendChild(fragment)
  }

  removeRow (event) {
    const row = event.target.closest('[data-criterion-row]')
    if (row) { row.remove() }
  }

  typeChanged (event) {
    const select = event.target
    const row = select.closest('[data-criterion-row]')
    if (!row) { return }

    row.querySelectorAll('[data-criterion-value]').forEach((element) => {
      element.hidden = element.dataset.criterionValue !== select.value
    })
  }
}
