import { Controller } from '@hotwired/stimulus'
import { Howl } from 'howler'

// Tunes the Web_Player into a Radio_Station's continuous MP3 Stream_Endpoint
// (Req 3.1, 3.3). It reuses the structure of `player.js` — a single Howl per
// source with `html5` streaming and an onplay/onstop lifecycle — but a
// Shared_Stream has no playlist and no seek: it is a live, always-on broadcast
// always served from its current position (Req 3.4), so this controller only
// exposes tune-in and stop.
//
//   <div data-controller="radio-station-player"
//        data-radio-station-player-url-value="https://.../radio/1/stream.mp3">
//     <button data-radio-station-player-target="playButton"
//             data-action="radio-station-player#play">Tune in</button>
//     <button data-radio-station-player-target="stopButton"
//             data-action="radio-station-player#stop">Stop</button>
//     <span data-radio-station-player-target="status"></span>
//   </div>
export default class extends Controller {
  static targets = ['playButton', 'stopButton', 'status']
  static values = {
    url: String,
    format: { type: String, default: 'mp3' },
    playingText: { type: String, default: 'Playing' },
    stoppedText: { type: String, default: 'Stopped' },
    loadingText: { type: String, default: 'Connecting...' },
    errorText: { type: String, default: 'Stream unavailable' }
  }

  disconnect () {
    this.#teardown()
  }

  play () {
    if (!this.hasUrlValue || this.urlValue === '') { return }

    this.#setStatus(this.loadingTextValue)

    // A live stream is always served from its current position, so a fresh Howl
    // is created on every tune-in rather than resuming a paused one.
    this.#teardown()

    this.howl = new Howl({
      src: [this.urlValue],
      format: [this.formatValue],
      html5: true,
      volume: 1.0,
      onplay: () => { this.#setPlayingStatus() },
      onstop: () => { this.#setStoppedStatus() },
      onloaderror: () => { this.#setErrorStatus() },
      onplayerror: () => { this.#setErrorStatus() }
    })

    this.howl.play()
  }

  stop () {
    this.#teardown()
    this.#setStoppedStatus()
  }

  #setPlayingStatus () {
    this.#setStatus(this.playingTextValue)
    this.#toggleButtons(true)
  }

  #setStoppedStatus () {
    this.#setStatus(this.stoppedTextValue)
    this.#toggleButtons(false)
  }

  #setErrorStatus () {
    this.#teardown()
    this.#setStatus(this.errorTextValue)
    this.#toggleButtons(false)
  }

  #setStatus (text) {
    if (this.hasStatusTarget) { this.statusTarget.textContent = text }
  }

  #toggleButtons (isPlaying) {
    if (this.hasPlayButtonTarget) {
      this.playButtonTarget.classList.toggle('u-display-none', isPlaying)
    }
    if (this.hasStopButtonTarget) {
      this.stopButtonTarget.classList.toggle('u-display-none', !isPlaying)
    }
  }

  #teardown () {
    if (this.howl) {
      this.howl.stop()
      this.howl.unload()
      this.howl = null
    }
  }
}
