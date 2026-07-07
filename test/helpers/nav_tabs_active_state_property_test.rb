# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 8 of the audiobook-resume-and-media-ui
# feature.
#
# Design property (audiobook-resume-and-media-ui, Property 8):
#   For any current controller name, each social-listening tab (Radio Stations,
#   Party Sessions, Co-listen Sessions) is active if and only if the current
#   controller equals that section's controller; each tab's active state is
#   evaluated independently, so a controller outside all three sections leaves
#   all three inactive and no controller is forced to make exactly one of the
#   three active.
#
# This exercises the pure seam `NavTabs.active?(section, current_controller)`.
# Generated controller names include the three section controllers themselves
# and arbitrary other names (guaranteed not to collide with the three). For each
# generated controller it asserts:
#   (per-tab iff, Req 9.4, 9.5, 9.6) each section tab is active iff the current
#     controller equals that section's mapped controller;
#   (all-inactive, Req 9.9) a controller outside all three sections leaves all
#     three tabs inactive;
#   (independence / no forced-single, Req 9.10) because each check is evaluated
#     independently and the three controller names are distinct, at most one of
#     the three is active (exactly one for a section controller, zero otherwise)
#     -- nothing forces exactly one of the three to be active.
class NavTabsActiveStatePropertyTest < ActiveSupport::TestCase
  SECTIONS = NavTabs::SECTION_CONTROLLERS.keys.freeze
  SECTION_CONTROLLER_NAMES = NavTabs::SECTION_CONTROLLERS.values.freeze

  # Feature: audiobook-resume-and-media-ui, Property 8: Navigation active-state is per-tab and independent
  test "navigation active-state is per-tab and independent across section and arbitrary controllers" do
    check_property(iterations: 100) do
      if boolean
        # A controller that actually serves one of the three sections.
        SECTION_CONTROLLER_NAMES[range(0, SECTION_CONTROLLER_NAMES.length - 1)]
      else
        # An arbitrary other controller name, guaranteed not to be one of the
        # three section controllers.
        name = sized(range(1, 24)) { string(:alpha) }
        SECTION_CONTROLLER_NAMES.include?(name) ? "#{name}_other" : name
      end
    end.check do |current_controller|
      is_section_controller = SECTION_CONTROLLER_NAMES.include?(current_controller)

      # (Req 9.4, 9.5, 9.6) Each tab is active iff the current controller equals
      # that section's mapped controller -- evaluated independently per tab.
      SECTIONS.each do |section|
        expected = (NavTabs::SECTION_CONTROLLERS[section] == current_controller)
        assert_equal expected, NavTabs.active?(section, current_controller),
          "expected tab #{section.inspect} active == #{expected} for controller #{current_controller.inspect}"
      end

      active_count = SECTIONS.count { |section| NavTabs.active?(section, current_controller) }

      if is_section_controller
        # (Req 9.10) The three controller names are distinct, so a section
        # controller activates exactly one tab -- never more.
        assert_equal 1, active_count,
          "expected exactly one active tab for section controller #{current_controller.inspect}"
      else
        # (Req 9.9) A controller outside all three sections leaves them inactive;
        # nothing forces one of the three to be active (Req 9.10).
        assert_equal 0, active_count,
          "expected no active tabs for non-section controller #{current_controller.inspect}"
      end
    end
  end
end
