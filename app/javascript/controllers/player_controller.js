import { Controller } from '@hotwired/stimulus'
import { Howl } from 'howler'
import { formatDuration, dispatchEvent, fetchRequest } from '../helper'
import { PositionSync } from '../player'
import { installEventHandler } from './mixins/event_handler'

export default class extends Controller {
  static targets = [
    'header',
    'image',
    'backgroundImage',
    'songName',
    'artistName',
    'albumName',
    'songDuration',
    'songTimer',
    'progress',
    'playButton',
    'pauseButton',
    'favoriteButton',
    'unFavoriteButton',
    'modeButton',
    'loader',
    'volume'
  ]

  initialize () {
    this.#initPlayer()
    this.#initMode()
    this.#initVolume()
    this.#initPositionSync()

    installEventHandler(this)
  }

  connect () {
    this.handleEvent('player:beforePlaying', { with: this.#setBeforePlayingStatus })
    this.handleEvent('player:loaded', { with: this.#resumeOnOpen })
    this.handleEvent('player:playing', { with: this.#setPlayingStatus })
    this.handleEvent('player:pause', { with: this.#setPauseStatus })
    this.handleEvent('player:stop', { with: this.#setStopStatus })
    this.handleEvent('player:end', { with: this.#setEndStatus })

    // Record + send the current Playback_Position before the page unloads or
    // Turbo navigates away from a playing Resumable_Track (Req 2.3).
    window.addEventListener('beforeunload', this.#recordPosition)
    document.addEventListener('turbo:before-visit', this.#recordPosition)
  }

  disconnect () {
    window.removeEventListener('beforeunload', this.#recordPosition)
    document.removeEventListener('turbo:before-visit', this.#recordPosition)
    this.#clearRecordInterval()
  }

  play () {
    this.player.play()
  }

  pause () {
    this.player.pause()
  }

  toggleFavorite (event) {
    if (!event.detail.success) { return }

    const isFavorited = this.currentSong.is_favorited

    this.currentSong.is_favorited = !isFavorited
    this.favoriteButtonTarget.classList.toggle('u-display-none', !isFavorited)
    this.unFavoriteButtonTarget.classList.toggle('u-display-none', isFavorited)
  }

  nextMode () {
    if (this.currentModeIndex + 1 >= this.modes.length) {
      this.currentModeIndex = 0
    } else {
      this.currentModeIndex += 1
    }

    this.updateMode()
  }

  updateMode () {
    this.modeButtonTargets.forEach((element) => {
      element.classList.toggle('u-display-none', element !== this.modeButtonTargets[this.currentModeIndex])
    })

    this.player.playlist.isShuffled = (this.currentMode === 'shuffle')
  }

  next () {
    this.player.next()
  }

  previous () {
    this.player.previous()
  }

  // Start-from-beginning control (Req 3.5): begin playback from the start
  // regardless of any stored Playback_Position. Setting skipResume makes the
  // next track open skip resume (consumed once by #resumeOnOpen). When a track
  // is already open, seek to 0 immediately and reflect it in the progress bar
  // and elapsed-time display so the change is visible right away (Req 3.6).
  startFromBeginning () {
    this.skipResume = true

    if (this.currentSong.howl) {
      this.player.seek(0)
      window.requestAnimationFrame(this.#setProgress.bind(this))
      this.#setTimer()
    }
  }

  seek (event) {
    this.player.seek((event.offsetX / event.target.offsetWidth) * this.currentSong.duration)
    window.requestAnimationFrame(this.#setProgress.bind(this))
    this.#recordPosition()
  }

  volume (event) {
    this.#setVolume(event.target.value)
  }

  mute () {
    this.#setVolume(0)
  }

  maxVolume () {
    this.#setVolume(1)
  }

  collapse () {
    document.querySelector('#js-sidebar').classList.remove('is-expanded')
  }

  get player () {
    return App.player
  }

  get currentIndex () {
    return this.player.currentIndex
  }

  get currentSong () {
    return this.player.currentSong
  }

  get currentMode () {
    return this.modes[this.currentModeIndex]
  }

  get currentTime () {
    const currentTime = this.currentSong.howl ? this.currentSong.howl.seek() : 0
    return (typeof currentTime === 'number') ? Math.round(currentTime) : 0
  }

  get isEndOfPlaylist () {
    return this.currentIndex === this.player.playlist.length - 1
  }

  #setBeforePlayingStatus = () => {
    this.headerTarget.classList.add('is-expanded')
    this.loaderTarget.classList.remove('u-display-none')
    this.favoriteButtonTarget.querySelector('button').disabled = false
    this.songTimerTarget.textContent = formatDuration(0)
  }

  // Reconcile + auto-seek on open (Req 3.1–3.4, 6.3, 6.4, 3.6). Fires on
  // `player:loaded`, which the Player dispatches once per freshly loaded Howl —
  // i.e. when a track is opened, not on every unpause — so the resumed position
  // is applied exactly once. At this point currentSong is set and its Howl is
  // loaded, so player.seek is safe.
  #resumeOnOpen = () => {
    const { currentSong } = this

    // A pending "start from beginning" request (Req 3.5) skips resume for this
    // open only; the start-from-beginning control sets skipResume.
    if (this.skipResume) {
      this.skipResume = false
      return
    }

    // Non-resumable tracks are never auto-resumed.
    if (!PositionSync.resumable(currentSong)) { return }

    // Local_Position_Store value ({ position_seconds, updated_at }) and the
    // Server's authoritative resume_position ({ position_seconds, finished,
    // updated_at }), either of which may be absent.
    const local = this.positionSync.readLocal(currentSong.id)
    const server = currentSong.resume_position || null

    if (!local && !server) { return }

    // Pick the more recently updated side via the mirrored reconciler (Req 6.3);
    // a tie or a missing client timestamp resolves to the Server.
    const side = PositionSync.choose(
      server && server.updated_at,
      local && local.updated_at
    )
    const chosen = side === 'client' ? local : server

    // The Local_Position_Store does not persist a finished flag, so a client-won
    // choice treats finished as false; resumeTarget still applies the
    // remaining-time backup internally.
    const position = chosen ? Number(chosen.position_seconds) : 0
    const finished = !!(chosen && chosen.finished)

    const target = this.positionSync.resumeTarget(position, currentSong.duration, finished)

    if (target > 0) {
      this.player.seek(target)

      // Reflect the resumed position in the progress bar and elapsed-time
      // display (Req 3.6). Both read currentTime, which now reflects the seek.
      window.requestAnimationFrame(this.#setProgress.bind(this))
      this.#setTimer()
    }

    // Req 6.4: when only a Local_Position_Store value exists, push it to the
    // Server so the Server becomes consistent with it. Reuses the best-effort
    // send path (Req 2.8).
    if (local && !server) {
      this.#sendPosition(currentSong.id, Number(local.position_seconds))
    }
  }

  #setPlayingStatus = () => {
    const { currentSong } = this
    const favoriteSongUrl = `/favorite_playlist/songs?song_id=${currentSong.id}`
    const unFavoriteSongUrl = `/favorite_playlist/songs/${currentSong.id}`

    this.imageTarget.src = currentSong.album_image_urls.small
    this.backgroundImageTarget.style.backgroundImage = `url(${currentSong.album_image_urls.small})`
    this.songNameTarget.textContent = currentSong.name
    this.artistNameTarget.textContent = currentSong.artist_name
    this.albumNameTarget.textContent = currentSong.album_name
    this.songDurationTarget.textContent = formatDuration(currentSong.duration)

    this.pauseButtonTarget.classList.remove('u-display-none')
    this.playButtonTarget.classList.add('u-display-none')
    this.loaderTarget.classList.add('u-display-none')

    this.favoriteButtonTarget.classList.toggle('u-display-none', currentSong.is_favorited)
    this.unFavoriteButtonTarget.classList.toggle('u-display-none', !currentSong.is_favorited)
    this.favoriteButtonTarget.action = favoriteSongUrl
    this.unFavoriteButtonTarget.action = unFavoriteSongUrl

    window.requestAnimationFrame(this.#setProgress.bind(this))
    this.timerInterval = setInterval(this.#setTimer.bind(this), 1000)

    // While a Resumable_Track plays, record the Playback_Position to the
    // Local_Position_Store and send it to the Server at least once every
    // Save_Interval (Req 2.1, 2.2). Non-resumable tracks are skipped entirely.
    this.#startRecording()

    // let playlist can show current playing song
    dispatchEvent(document, 'songs:showPlaying')
  }

  #setPauseStatus = () => {
    this.#clearTimerInterval()

    // Record + send on pause (Req 2.3) before tearing down the interval.
    this.#recordPosition()
    this.#clearRecordInterval()

    this.pauseButtonTarget.classList.add('u-display-none')
    this.playButtonTarget.classList.remove('u-display-none')
  }

  #setStopStatus = () => {
    this.#setPauseStatus()

    if (!this.currentSong.id) {
      this.headerTarget.classList.remove('is-expanded')
      dispatchEvent(document, 'songs:hidePlaying')
    }
  }

  #setEndStatus = () => {
    this.#clearTimerInterval()

    // Record + send when a Resumable_Track reaches its end (Req 2.3), carrying
    // an explicit finished signal so the Server marks the Playback_Position_Record
    // finished for that Resumable_Track (Req 5.2).
    this.#recordFinished()
    this.#clearRecordInterval()

    switch (this.currentMode) {
      case 'noRepeat':
        if (this.isEndOfPlaylist) {
          this.player.stop()
        } else {
          this.next()
        }
        break
      case 'single':
        this.player.play()
        break
      default:
        this.next()
    }
  }

  #setProgress () {
    this.progressTarget.value = (this.currentTime / this.currentSong.duration) * 100 || 0

    if (this.player.isPlaying) {
      window.requestAnimationFrame(this.#setProgress.bind(this))
    }
  }

  #setTimer () {
    this.songTimerTarget.textContent = formatDuration(this.currentTime)
  }

  #setVolume (value) {
    const progress = value * 100

    this.volumeTarget.style.setProperty('--progress', `${progress}%`)
    this.player.volume(value)
    window.localStorage.setItem('playerVolume', value)

    if (this.volumeTarget.value !== value) { this.volumeTarget.value = value }
  }

  #clearTimerInterval () {
    if (this.timerInterval) {
      clearInterval(this.timerInterval)
    }
  }

  // Start recording the Playback_Position for a playing Resumable_Track: write
  // to the Local_Position_Store and send to the Server immediately, then again
  // at least once every Save_Interval (Req 2.1, 2.2). Non-resumable tracks are
  // skipped entirely so no interval is started.
  #startRecording () {
    if (!PositionSync.resumable(this.currentSong)) { return }

    this.#recordPosition()
    this.recordInterval = setInterval(this.#recordPosition, this.positionSync.constants.saveInterval * 1000)
  }

  // Record the current Playback_Position to the Local_Position_Store and send it
  // to the Server (Req 2.1, 2.2, 2.3). Skips non-resumable tracks entirely. Kept
  // as an arrow field so it can be used directly as an event listener reference.
  #recordPosition = () => {
    const { currentSong } = this
    if (!PositionSync.resumable(currentSong)) { return }

    this.positionSync.writeLocal(currentSong.id, this.currentTime)
    this.#sendPosition(currentSong.id, this.currentTime)
  }

  // Record the end-of-track Playback_Position to the Local_Position_Store and
  // send it to the Server with an explicit finished signal (Req 5.2). Skips
  // non-resumable tracks entirely, mirroring #recordPosition. The Server marks
  // the (User, Song) Playback_Position_Record finished on receipt.
  #recordFinished = () => {
    const { currentSong } = this
    if (!PositionSync.resumable(currentSong)) { return }

    this.positionSync.writeLocal(currentSong.id, this.currentTime)
    this.#sendPosition(currentSong.id, this.currentTime, { finished: true })
  }

  // PUT the Playback_Position to the client-agnostic Server endpoint, carrying a
  // client timestamp for reconciliation (Req 2.2, 6.5). When finished is true,
  // the explicit finished indication is included so the Server marks the record
  // finished (Req 5.2). The save is best-effort (Req 2.8): a failed PUT — a
  // rejected fetch (network failure) or a non-2xx response — is swallowed so
  // playback continues uninterrupted. The Local_Position_Store value written by
  // writeLocal is never cleared here, so it is retained for a later save or
  // reconciliation.
  #sendPosition (songId, positionSeconds, { finished = false } = {}) {
    const playbackPosition = {
      position_seconds: positionSeconds,
      client_updated_at: new Date().toISOString()
    }

    if (finished) { playbackPosition.finished = true }

    fetchRequest(`/songs/${songId}/playback_position`, {
      method: 'PUT',
      body: JSON.stringify({ playback_position: playbackPosition })
    }).catch(() => {
      // Swallow the failure: playback keeps going and the localStorage value
      // stays put for later save/reconciliation.
    })
  }

  #clearRecordInterval () {
    if (this.recordInterval) {
      clearInterval(this.recordInterval)
    }
  }

  #initPlayer () {
    // Hack for Safari issue of can not play song when first time page loaded.
    // So call Howl init function manually let document have audio unlock event when click or touch.
    // When first time user interact page the audio will be unlocked.
    new Howl({ src: [''], format: ['mp3'] }) // eslint-disable-line no-new
  }

  #initMode () {
    this.modes = ['noRepeat', 'repeat', 'single', 'shuffle']
    this.currentModeIndex = 0
    this.updateMode()
  }

  #initVolume () {
    const volume = window.localStorage.getItem('playerVolume') || 1
    this.#setVolume(volume)
  }

  #initPositionSync () {
    this.positionSync = new PositionSync({ player: this.player })

    // When set, the next track open starts from the beginning regardless of any
    // stored Playback_Position. The start-from-beginning control (Req 3.5) sets
    // this flag; #resumeOnOpen consumes it for a single open.
    this.skipResume = false
  }
}
