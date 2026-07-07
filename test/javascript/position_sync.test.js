// Feature: audiobook-resume-and-media-ui — JS tests for PositionSync behavior (task 6.7)
//
// PositionSync (app/javascript/player.js) is the Web_Player collaborator that
// holds the correctness-sensitive playback-resume decisions mirrored from the
// Ruby seams: the reconciliation choice (PositionReconciler.choose), the
// resume-target decision (PositionPolicy.resume_target / finished?), the
// Local_Position_Store read/write, and the resumable guard. These are the parts
// of the browser behavior that are unit-testable without a browser; they are
// exercised here against the real app source under Node's built-in test runner.
//
// Covered here (as far as is practical without a browser/system harness):
//   - Req 2.1: current position is recorded to the Local_Position_Store with a
//     local timestamp (writeLocal) and read back (readLocal).
//   - Req 3.1: a meaningful, unfinished stored position produces a resume target
//     equal to that position (the value the player seeks to on open).
//   - Req 6.3: local-vs-server reconciliation picks the more-recently-updated
//     side; ties / missing client timestamp resolve to the Server.
//   - Req 5.1 backup / Req 3.4: the remaining-time finished computation and its
//     effect on the resume target.
//   - Req 1.1/1.3 guard: non-resumable tracks are skipped (resumable predicate).
//
// NOT covered here — these live in the Stimulus player_controller.js and require
// a browser/Stimulus/Howler system harness the project does not have (see the
// note at the bottom of this file):
//   - Req 2.1/2.2/2.3 interval cadence and pause/stop/seek/beforeunload event
//     wiring; Req 2.8 best-effort fetch; Req 3.5 start-from-beginning seek(0);
//     Req 3.6 progress-bar/timer rendering; Req 5.2 the finished:true PUT;
//     Req 6.4 the local-only push PUT. The decisions those behaviors rely on
//     (choose / resumeTarget / finished / resumable / read+write) are covered.

import { describe, it, beforeEach } from 'node:test'
import assert from 'node:assert/strict'

// Stubs must be installed before player.js is imported (its `howler` import
// reads `window` at evaluation time). ESM evaluates imports in source order.
import { localStorage, setConstantsElement } from './support/dom_stubs.js'
import { PositionSync } from '../../app/javascript/player.js'

const DURATION = 3600 // seconds — a one-hour Resumable_Track

describe('PositionSync.resumable (Req 1.1, 1.3 guard)', () => {
  it('is false for null / undefined songs', () => {
    assert.equal(PositionSync.resumable(null), false)
    assert.equal(PositionSync.resumable(undefined), false)
  })

  it('is false when the song is not flagged resumable', () => {
    assert.equal(PositionSync.resumable({ id: 1 }), false)
    assert.equal(PositionSync.resumable({ id: 1, resumable: false }), false)
  })

  it('is true when the song carries the resumable flag', () => {
    assert.equal(PositionSync.resumable({ id: 1, resumable: true }), true)
  })
})

describe('PositionSync.storageKey', () => {
  it('keys the Local_Position_Store by song id', () => {
    assert.equal(PositionSync.storageKey(42), 'playbackPosition:42')
  })
})

describe('PositionSync local store round-trip (Req 2.1)', () => {
  let sync

  beforeEach(() => {
    localStorage.clear()
    sync = new PositionSync({})
  })

  it('writeLocal stores position_seconds plus an ISO local timestamp', () => {
    const before = Date.now()
    const record = sync.writeLocal(7, 613)
    const after = Date.now()

    assert.equal(record.position_seconds, 613)
    const stamp = Date.parse(record.updated_at)
    assert.ok(stamp >= before && stamp <= after, 'updated_at is a current ISO timestamp')
  })

  it('readLocal returns the value written under the song key', () => {
    sync.writeLocal(7, 613)
    const read = sync.readLocal(7)

    assert.equal(read.position_seconds, 613)
    assert.ok(typeof read.updated_at === 'string')
  })

  it('readLocal returns null when nothing is stored', () => {
    assert.equal(sync.readLocal(999), null)
  })

  it('readLocal returns null (does not throw) for malformed JSON', () => {
    localStorage.setItem(PositionSync.storageKey(8), 'not-json{')
    assert.equal(sync.readLocal(8), null)
  })

  it('keeps positions for different songs independent', () => {
    sync.writeLocal(1, 100)
    sync.writeLocal(2, 200)

    assert.equal(sync.readLocal(1).position_seconds, 100)
    assert.equal(sync.readLocal(2).position_seconds, 200)
  })
})

describe('PositionSync.choose — reconciliation (Req 6.3)', () => {
  const older = '2026-07-05T12:00:00.000Z'
  const newer = '2026-07-05T12:05:00.000Z'

  it('picks the server when there is no client timestamp', () => {
    assert.equal(PositionSync.choose(older, null), 'server')
    assert.equal(PositionSync.choose(older, undefined), 'server')
  })

  it('picks the client when only a client timestamp exists', () => {
    assert.equal(PositionSync.choose(null, newer), 'client')
  })

  it('picks the more recently updated side', () => {
    assert.equal(PositionSync.choose(older, newer), 'client')
    assert.equal(PositionSync.choose(newer, older), 'server')
  })

  it('resolves a tie to the server (authoritative record wins)', () => {
    assert.equal(PositionSync.choose(newer, newer), 'server')
  })
})

describe('PositionSync#finished — remaining-time backup (Req 5.1)', () => {
  let sync

  beforeEach(() => { sync = new PositionSync({}) })

  it('is true at or below the finished threshold (30s remaining)', () => {
    assert.equal(sync.finished(DURATION - 30, DURATION), true) // exactly at threshold
    assert.equal(sync.finished(DURATION - 5, DURATION), true)
    assert.equal(sync.finished(DURATION, DURATION), true)
  })

  it('is false when more than the threshold remains', () => {
    assert.equal(sync.finished(DURATION - 31, DURATION), false)
    assert.equal(sync.finished(0, DURATION), false)
  })
})

describe('PositionSync#resumeTarget — resume decision (Req 3.1, 3.4, 3.6)', () => {
  let sync

  beforeEach(() => { sync = new PositionSync({}) })

  it('returns the stored position for a meaningful, unfinished point (Req 3.1)', () => {
    assert.equal(sync.resumeTarget(613, DURATION, false), 613)
  })

  it('returns the position exactly at the minimum resume boundary (10s)', () => {
    assert.equal(sync.resumeTarget(10, DURATION, false), 10)
  })

  it('returns 0 below the minimum resume position (Req 3.3)', () => {
    assert.equal(sync.resumeTarget(9, DURATION, false), 0)
    assert.equal(sync.resumeTarget(0, DURATION, false), 0)
  })

  it('returns 0 when the record is marked finished (Req 3.4)', () => {
    assert.equal(sync.resumeTarget(613, DURATION, true), 0)
  })

  it('returns 0 within the finished threshold even without a finished flag (Req 3.4 backup)', () => {
    assert.equal(sync.resumeTarget(DURATION - 20, DURATION, false), 0)
  })
})

describe('PositionSync open-time decision: choose + resumeTarget (Req 3.1, 6.3)', () => {
  let sync

  beforeEach(() => {
    localStorage.clear()
    sync = new PositionSync({})
  })

  // Mirrors the decision #resumeOnOpen makes: reconcile local vs server, then
  // compute the seek target from the chosen side.
  function openTarget (local, server) {
    const side = PositionSync.choose(server && server.updated_at, local && local.updated_at)
    const chosen = side === 'client' ? local : server
    const position = chosen ? Number(chosen.position_seconds) : 0
    const finished = !!(chosen && chosen.finished)
    return sync.resumeTarget(position, DURATION, finished)
  }

  it('seeks to the more-recent local position when local wins (Req 6.3)', () => {
    const local = { position_seconds: 900, updated_at: '2026-07-05T12:05:00.000Z' }
    const server = { position_seconds: 300, finished: false, updated_at: '2026-07-05T12:00:00.000Z' }
    assert.equal(openTarget(local, server), 900)
  })

  it('seeks to the server position when the server is more recent (Req 6.3)', () => {
    const local = { position_seconds: 900, updated_at: '2026-07-05T12:00:00.000Z' }
    const server = { position_seconds: 300, finished: false, updated_at: '2026-07-05T12:05:00.000Z' }
    assert.equal(openTarget(local, server), 300)
  })

  it('uses the local value when only local exists (feeds the Req 6.4 push)', () => {
    const local = { position_seconds: 450, updated_at: '2026-07-05T12:00:00.000Z' }
    assert.equal(openTarget(local, null), 450)
  })

  it('starts from 0 when the chosen (server) record is finished (Req 3.4)', () => {
    const server = { position_seconds: 900, finished: true, updated_at: '2026-07-05T12:00:00.000Z' }
    assert.equal(openTarget(null, server), 0)
  })
})

describe('PositionSync.readConstants — mirrors Ruby constants', () => {
  beforeEach(() => setConstantsElement(null))

  it('falls back to mirrored defaults when the block is absent', () => {
    const sync = new PositionSync({})
    assert.deepEqual(sync.constants, {
      longTrackThreshold: 1200,
      minimumResumePosition: 10,
      finishedThreshold: 30,
      saveInterval: 10
    })
  })

  it('reads finite numeric overrides from the data-attribute block', () => {
    setConstantsElement({
      longTrackThreshold: '1800',
      minimumResumePosition: '15',
      finishedThreshold: '45',
      saveInterval: '5'
    })

    const sync = new PositionSync({})
    assert.equal(sync.constants.longTrackThreshold, 1800)
    assert.equal(sync.constants.minimumResumePosition, 15)
    assert.equal(sync.constants.finishedThreshold, 45)
    assert.equal(sync.constants.saveInterval, 5)
  })

  it('ignores non-finite values and keeps the defaults for them', () => {
    setConstantsElement({
      longTrackThreshold: 'not-a-number',
      saveInterval: '5'
    })

    const sync = new PositionSync({})
    assert.equal(sync.constants.longTrackThreshold, 1200) // default retained
    assert.equal(sync.constants.saveInterval, 5) // override applied
  })
})
