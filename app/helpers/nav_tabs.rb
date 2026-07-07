# frozen_string_literal: true

# NavTabs is a pure seam (no I/O) that decides whether a Global_Navigation tab
# for one of the social-listening sections is active, given the controller
# currently handling the request.
#
# Each of the three sections maps to the controller that serves it. The active
# check is evaluated independently per tab: a tab is active if and only if the
# current controller equals that section's controller. Because each check is
# independent, a controller that is none of the three leaves all three inactive
# (Req 9.9), and nothing forces exactly one of the three to be active (Req 9.10).
#
# Home and Library tabs are unaffected by this seam (Req 9.8).
module NavTabs
  SECTION_CONTROLLERS = {
    radio_stations: "radio_stations",
    party_sessions: "party_sessions",
    co_listen_sessions: "co_listen_sessions"
  }.freeze

  module_function

  # Pure: is the given section tab active for the current controller?
  # Returns false for unknown sections (Req 9.4, 9.5, 9.6, 9.9, 9.10).
  def active?(section, current_controller)
    SECTION_CONTROLLERS[section] == current_controller
  end
end
