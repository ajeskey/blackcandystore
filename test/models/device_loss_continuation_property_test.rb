# frozen_string_literal: true

require "test_helper"

# Property-based test for the Party device-dispatch device-loss seam of the
# radio-party-colisten feature (design Property 24).
#
# This exercises the pure PartyPlaybackDispatcher.decide_device_loss decision
# directly — the seam that decides what happens to a playing Party_Session when
# one of its Host-selected Output_Devices becomes unavailable (Req 6.4). The
# decision is side-effect-free: it neither persists the selection nor contacts
# the Playback_Sidecar, so it can be property-tested in isolation without the
# database, the sequencer, or any I/O.
#
# The decision must satisfy, for any selected-device set and any lost device
# (whether or not the lost device is part of the current selection):
#   * the remaining selection is exactly the selection minus the lost device;
#   * playback continues (action :continue) iff at least one device remains,
#     and stops (action :stop) otherwise; and
#   * the caller's original selection is otherwise unchanged (no mutation).
class DeviceLossContinuationPropertyTest < ActiveSupport::TestCase
  # Feature: radio-party-colisten, Property 24: Device-loss continuation
  test "losing a selected Output_Device leaves the remaining selection and continues playback on it, stopping only when no selected device remains" do
    check_property(iterations: 100) do
      # An arbitrary selection of Output_Device ids (possibly empty, possibly
      # with duplicates so id normalization is exercised) and a lost device id
      # that is sometimes drawn from the selection and sometimes outside it, so
      # both the "lost device was selected" and "lost device was never
      # selected" cases are covered.
      selection = array(range(0, 8)) { range(1, 20) }
      lost_from_selection = !selection.empty? && choose(true, false)
      lost_device_id = lost_from_selection ? choose(*selection) : range(21, 40)

      [ selection, lost_device_id ]
    end.check do |(selection, lost_device_id)|
      # A defensive copy so we can assert the decision does not mutate the
      # caller's selection.
      original = selection.dup

      decision = PartyPlaybackDispatcher.decide_device_loss(
        active_device_ids: selection,
        lost_device_id: lost_device_id
      )

      # remaining = selection − lost, over the normalized (integer, de-duped,
      # order-preserving) selection the dispatcher works with.
      expected_remaining = selection.map(&:to_i).uniq - [ lost_device_id.to_i ]

      assert_equal expected_remaining, decision.remaining_device_ids,
        "remaining devices must be the selection minus the lost device"

      # The lost device is never part of the remaining selection.
      assert_not_includes decision.remaining_device_ids, lost_device_id.to_i,
        "the lost device must not remain in the selection"

      if expected_remaining.empty?
        # Last selected device lost → playback stops for the session.
        assert_equal PartyPlaybackDispatcher::ACTION_STOP, decision.action,
          "playback must stop when no selected device remains"
        assert decision.stop?, "decision must report stop? when nothing remains"
        assert_not decision.continue?, "decision must not report continue? when nothing remains"
      else
        # Devices remain → playback continues on them.
        assert_equal PartyPlaybackDispatcher::ACTION_CONTINUE, decision.action,
          "playback must continue while a selected device remains"
        assert decision.continue?, "decision must report continue? while devices remain"
        assert_not decision.stop?, "decision must not report stop? while devices remain"
      end

      # The decision is pure: the caller's selection is left untouched.
      assert_equal original, selection,
        "decide_device_loss must not mutate the caller's selection"
    end
  end
end
