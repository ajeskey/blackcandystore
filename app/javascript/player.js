import { Howl, Howler } from 'howler'
import { dispatchEvent } from './helper'
import Playlist from './playlist'

class Player {
  currentSong = {}
  isPlaying = false
  playlist = new Playlist()

  playOn (index) {
    if (this.playlist.length === 0) { return }

    dispatchEvent(document, 'player:beforePlaying')

    const song = this.playlist.songs[index]
    this.currentSong = song
    this.isPlaying = true

    if (!song.howl) {
      song.howl = new Howl({
        src: [song.url],
        format: [song.format],
        html5: true,
        volume: 1.0,
        onload: () => { dispatchEvent(document, 'player:loaded') },
        onplay: () => { dispatchEvent(document, 'player:playing') },
        onpause: () => { dispatchEvent(document, 'player:pause') },
        onend: () => { dispatchEvent(document, 'player:end') },
        onstop: () => { dispatchEvent(document, 'player:stop') }
      })
    }

    song.howl.play()
  }

  play () {
    this.isPlaying = true

    if (!this.currentSong.howl) {
      this.playOn(this.currentIndex)
    } else {
      this.currentSong.howl.play()
    }
  }

  pause () {
    this.isPlaying = false
    this.currentSong.howl && this.currentSong.howl.pause()
  }

  stop () {
    this.isPlaying = false

    Howler.stop()

    // reset current song
    this.currentSong = {}
  }

  next () {
    this.skipTo(this.currentIndex + 1)
  }

  previous () {
    this.skipTo(this.currentIndex - 1)
  }

  skipTo (index) {
    this.currentSong.howl && this.currentSong.howl.stop()

    if (index >= this.playlist.length) {
      index = 0
    } else if (index < 0) {
      index = this.playlist.length - 1
    }

    this.playOn(index)
  }

  seek (seconds) {
    this.currentSong.howl.seek(seconds)
  }

  volume (value) {
    Howler.volume(value)
  }

  get currentIndex () {
    return Math.max(this.playlist.indexOf(this.currentSong.id), 0)
  }
}

// Fallback values mirroring the Ruby PlaybackPosition constants. The
// authoritative values are surfaced through the [data-playback-constants] block
// rendered by the player view (app/views/shared/_player.html.erb) so JS and Ruby
// never drift; these defaults only apply when that block is absent.
const DEFAULT_CONSTANTS = {
  longTrackThreshold: 1200,
  minimumResumePosition: 10,
  finishedThreshold: 30,
  saveInterval: 10
}

// PositionSync is the Web_Player collaborator for playback-position resume. This
// file establishes the collaborator API the player controller will call:
//   - the fixed constants, read from the data-attribute block so they mirror Ruby
//   - Local_Position_Store (localStorage) reads/writes keyed by Song id
//   - the pure decision helpers mirrored from the Ruby seams
//     (PositionReconciler.choose and PositionPolicy.resume_target)
//   - a resumable guard so non-resumable tracks are skipped entirely
// Recording (interval + event saves), best-effort saving, reconcile + auto-seek
// on open, the start-from-beginning control, and the finished signal are wired
// from player_controller.js in later tasks.
class PositionSync {
  constructor ({ player = null, constants = null } = {}) {
    this.player = player
    this.constants = { ...DEFAULT_CONSTANTS, ...PositionSync.readConstants(), ...(constants || {}) }
  }

  // Read the fixed constants from the data-attribute block rendered by the
  // player view. Only finite numeric values override the defaults, so a missing
  // or malformed block leaves the mirrored fallbacks in place.
  static readConstants () {
    const element = document.querySelector('[data-playback-constants]')
    if (!element) { return {} }

    const { dataset } = element
    const values = {
      longTrackThreshold: Number(dataset.longTrackThreshold),
      minimumResumePosition: Number(dataset.minimumResumePosition),
      finishedThreshold: Number(dataset.finishedThreshold),
      saveInterval: Number(dataset.saveInterval)
    }

    return Object.fromEntries(
      Object.entries(values).filter(([, value]) => Number.isFinite(value))
    )
  }

  // Whether a track qualifies for position resume. `resumable` is carried on the
  // Song by song_json_builder. Non-resumable tracks are skipped entirely — no
  // localStorage write, no server save, and no auto-seek on open.
  static resumable (song) {
    return !!(song && song.resumable)
  }

  // localStorage key for a Song's locally stored Playback_Position.
  static storageKey (songId) {
    return `playbackPosition:${songId}`
  }

  // Read the Local_Position_Store value for a Song, or null when absent or
  // unparseable. Shape: { position_seconds, updated_at }.
  readLocal (songId) {
    const raw = window.localStorage.getItem(PositionSync.storageKey(songId))
    if (!raw) { return null }

    try {
      return JSON.parse(raw)
    } catch (error) {
      return null
    }
  }

  // Write the current Playback_Position to the Local_Position_Store with a local
  // timestamp (Req 2.1). Returns the stored record.
  writeLocal (songId, positionSeconds) {
    const record = {
      position_seconds: positionSeconds,
      updated_at: new Date().toISOString()
    }

    window.localStorage.setItem(PositionSync.storageKey(songId), JSON.stringify(record))
    return record
  }

  // Mirror of Playback::PositionReconciler.choose (Req 6.3): the more recently
  // updated side wins; a tie or a missing client timestamp resolves to the
  // server so the authoritative record wins. Returns 'server' or 'client'.
  static choose (serverUpdatedAt, clientUpdatedAt) {
    if (clientUpdatedAt == null) { return 'server' }
    if (serverUpdatedAt == null) { return 'client' }

    return new Date(clientUpdatedAt) > new Date(serverUpdatedAt) ? 'client' : 'server'
  }

  // Mirror of Playback::PositionPolicy#finished? — the remaining-time backup:
  // finished when the remaining time is at or below the Finished_Threshold.
  finished (position, duration) {
    return (duration - position) <= this.constants.finishedThreshold
  }

  // Mirror of Playback::PositionPolicy#resume_target (Req 3.1–3.4): the number of
  // seconds the Web_Player should seek to when opening a track. Returns 0 (start)
  // unless there is a meaningful, unfinished resume point.
  resumeTarget (position, duration, finished) {
    if (finished) { return 0 }
    if (position < this.constants.minimumResumePosition) { return 0 }
    if (this.finished(position, duration)) { return 0 }

    return position
  }
}

export default Player
export { Player, PositionSync }
