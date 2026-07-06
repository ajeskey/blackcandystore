# frozen_string_literal: true

require "puma/plugin"

# Boot-time registration of ResumeStreamsJob (Req 10.4, 10.10).
#
# After a server restart Rails is the source of truth for which always-on
# broadcasts should exist: the Broadcaster holds no authoritative domain state,
# so on boot we re-establish every `started` Radio_Station and every non-expired
# `active` Co_Listen_Session (up to the concurrency cap). ResumeStreamsJob owns
# that decision and the Broadcaster re-establishment.
#
# This mirrors the MediaListener boot hook (lib/puma/plugin/media_listener.rb):
# hooking Puma's `on_booted` means resume runs only when the web server boots —
# never during the test suite, an asset precompile, a rake task, or a `rails
# console` session — which is exactly the guard we want. The job is enqueued
# (not run inline) so a slow or unavailable Broadcaster never blocks boot; the
# resume work happens in the background queue and is best-effort/idempotent.
Puma::Plugin.create do
  def start(launcher)
    launcher.events.on_booted { ResumeStreamsJob.perform_later unless Rails.env.test? }
  end
end
