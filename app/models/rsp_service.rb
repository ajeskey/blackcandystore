# frozen_string_literal: true

# RSP_Service exposes authorized local library content to Roku-style RSP
# Media_Clients (Req 15.2). It is enabled/disabled independently via the
# `enable_rsp` Setting flag (Req 15.3, 15.5); connecting clients are
# authenticated against the server's existing authentication model (Req 15.6,
# 15.7); and it serves ONLY local, authorized content — never Remote_Library
# content (Req 15.8, 15.10; Property 22).
#
# All of that behavior lives in MediaClientService; this subclass only names the
# `enable_rsp` flag. The RSP wire protocol itself is served by an external media
# server fronted by this boundary (see MediaClientService::Adapter) and is
# integration/smoke-tested in task 29.2.
class RSPService < MediaClientService
  def self.enable_setting
    :enable_rsp
  end
end
