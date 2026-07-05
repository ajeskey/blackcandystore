# frozen_string_literal: true

# Output_Device is a discovery-maintained record of an AirPlay or Chromecast
# target advertised on the local network (Req 13). It is a cache: Device
# Discovery inserts a row when a device is advertised, refreshes `reachable_at`
# while it stays advertised, and removes it once advertisements stop (Req 13.1,
# 13.3). Every device is classified as exactly one protocol (Req 13.6) and
# records whether it requires a password (Req 13.2, 13.4).
class OutputDevice < ApplicationRecord
  PROTOCOLS = %w[airplay chromecast].freeze

  validates :identifier, presence: true, uniqueness: true
  validates :protocol, inclusion: { in: PROTOCOLS }, allow_nil: true
end
