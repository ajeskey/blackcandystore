import { Controller } from '@hotwired/stimulus'
import { fetchRequest } from '../helper'

// Drives the Guest join flow opened from a Share_Link (Req 5.1, 9.2). A Guest is
// not a `User`: admission returns a non-cookie Bearer Guest_Token exactly once
// (only its keyed digest is persisted, Req 8.7), which every later Guest request
// must present. This controller POSTs the join to the client-agnostic JSON
// `guest_admit` endpoint, captures that token, stores it for the session so the
// Shared_Playlist client can attach it, and forwards the Guest to the playlist.
//
//   <div data-controller="guest-session"
//        data-guest-session-admit-url-value="/join/TOKEN.json"
//        data-guest-session-playlist-url-template-value="/shared_playlists/SHARED_PLAYLIST_ID/shared_playlist_entries">
//     <form data-action="guest-session#join">
//       <input data-guest-session-target="displayName">
//     </form>
//   </div>
export default class extends Controller {
  static targets = ['displayName', 'error']
  static values = {
    admitUrl: String,
    playlistUrlTemplate: String
  }

  static tokenStorageKey (sharedPlaylistId) {
    return `bc.guest_token.${sharedPlaylistId}`
  }

  static guestIdStorageKey (sharedPlaylistId) {
    return `bc.guest_id.${sharedPlaylistId}`
  }

  async join (event) {
    event.preventDefault()

    if (!this.hasAdmitUrlValue || this.admitUrlValue === '') { return }

    this.#hideError()

    try {
      const response = await fetchRequest(this.admitUrlValue, {
        method: 'POST',
        body: JSON.stringify({ display_name: this.#displayName() })
      })

      if (!response.ok) { return this.#showError() }

      const data = await response.json()
      const sharedPlaylistId = data.session && data.session.shared_playlist_id

      if (!data.guest_token || !sharedPlaylistId) { return this.#showError() }

      this.#storeToken(sharedPlaylistId, data.guest_token)
      this.#storeGuestId(sharedPlaylistId, data.guest && data.guest.id)
      window.location.assign(this.#playlistUrl(sharedPlaylistId))
    } catch {
      this.#showError()
    }
  }

  #displayName () {
    return this.hasDisplayNameTarget ? this.displayNameTarget.value : ''
  }

  #storeToken (sharedPlaylistId, token) {
    window.localStorage.setItem(
      this.constructor.tokenStorageKey(sharedPlaylistId),
      token
    )
  }

  #storeGuestId (sharedPlaylistId, guestId) {
    if (!guestId) { return }

    window.localStorage.setItem(
      this.constructor.guestIdStorageKey(sharedPlaylistId),
      guestId
    )
  }

  #playlistUrl (sharedPlaylistId) {
    return this.playlistUrlTemplateValue.replace('SHARED_PLAYLIST_ID', sharedPlaylistId)
  }

  #showError () {
    if (this.hasErrorTarget) { this.errorTarget.classList.remove('u-display-none') }
  }

  #hideError () {
    if (this.hasErrorTarget) { this.errorTarget.classList.add('u-display-none') }
  }
}
