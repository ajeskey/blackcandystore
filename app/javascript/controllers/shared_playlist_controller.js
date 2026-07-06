import { Controller } from '@hotwired/stimulus'
import Playlist from '../playlist'
import { fetchRequest } from '../helper'

// Drives the Shared_Playlist client of a Party_Session or Co_Listen_Session
// (Req 5.2, 6.6). It mirrors the rendered entries into a client-side `Playlist`
// (reusing `playlist.js`) so additions and removals update the list in place
// without a full reload.
//
// Two actors share this one surface:
//   * The Host reaches it through the normal cookie session; the plain
//     button_to/form submits already carry cookie + CSRF, so this controller
//     lets them proceed and only keeps the client Playlist in sync.
//   * A Guest reaches it holding a non-cookie Bearer Guest_Token (stored at
//     join, keyed by the Shared_Playlist id). When that token is present this
//     controller intercepts add/remove and drives the JSON API with an
//     `Authorization: Bearer` header, since a browser form cannot send it. A
//     Guest may only act on entries it added (Req 6.6); controls on other
//     entries are hidden and the server enforces the same rule.
//
//   <div data-controller="shared-playlist"
//        data-shared-playlist-entries-url-value="/shared_playlists/1/shared_playlist_entries.json"
//        data-shared-playlist-id-value="1">
export default class extends Controller {
  static targets = ['list', 'item', 'songSelect', 'empty']
  static values = {
    entriesUrl: String,
    id: Number
  }

  connect () {
    this.playlist = new Playlist()
    this.itemTargets.forEach((item, index) => {
      this.playlist.insert(index, { id: Number(item.dataset.songId) })
    })

    this.#hideForeignGuestControls()
  }

  // Add the selected Song to the Shared_Playlist. For a Host the native form
  // submit proceeds untouched; for a Guest we intercept and POST JSON with the
  // Bearer token.
  async add (event) {
    if (!this.#actingAsGuest()) { return }

    event.preventDefault()

    const songId = this.hasSongSelectTarget ? this.songSelectTarget.value : ''
    if (!songId) { return }

    const response = await fetchRequest(this.entriesUrlValue, {
      method: 'POST',
      headers: this.#authHeaders(),
      body: JSON.stringify({ song_id: songId })
    })

    if (response.ok) { window.location.reload() }
  }

  // Remove an entry. For a Host the native button_to DELETE proceeds untouched;
  // for a Guest we intercept and DELETE via the JSON API with the Bearer token,
  // then drop the row and keep the client Playlist in sync.
  async remove (event) {
    if (!this.#actingAsGuest()) { return }

    event.preventDefault()

    const form = event.currentTarget
    const item = form.closest('[data-entry-id]')

    const response = await fetchRequest(form.action, {
      method: 'DELETE',
      headers: this.#authHeaders()
    })

    if (response.ok && item) {
      this.playlist.deleteSong(Number(item.dataset.songId))
      item.remove()
    }
  }

  #actingAsGuest () {
    return this.#guestToken() !== null
  }

  #guestToken () {
    return window.localStorage.getItem(`bc.guest_token.${this.idValue}`)
  }

  #guestId () {
    return window.localStorage.getItem(`bc.guest_id.${this.idValue}`)
  }

  #authHeaders () {
    return { Authorization: `Bearer ${this.#guestToken()}` }
  }

  // A Guest may only remove/reorder entries it added (Req 6.6); hide the
  // controls on every other entry so the client matches the server's rule.
  #hideForeignGuestControls () {
    if (!this.#actingAsGuest()) { return }

    const guestId = this.#guestId()

    this.itemTargets.forEach((item) => {
      if (item.dataset.addedByGuestId !== guestId) {
        item.querySelectorAll('form').forEach((form) => {
          form.classList.add('u-display-none')
        })
      }
    })
  }
}
