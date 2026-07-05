# frozen_string_literal: true

# DAAP_Service exposes authorized local library content to iTunes-style DAAP
# Media_Clients (Req 15.1). It is enabled/disabled independently via the
# `enable_daap` Setting flag (Req 15.3, 15.4); connecting clients are
# authenticated against the server's existing authentication model (Req 15.6,
# 15.7); and it serves ONLY local, authorized content — never Remote_Library
# content (Req 15.8, 15.10; Property 22).
#
# All of that behavior lives in MediaClientService; this subclass only names the
# `enable_daap` flag. The DAAP wire protocol itself is served by an external
# media server fronted by this boundary (see MediaClientService::Adapter) and is
# integration/smoke-tested in task 29.2.
class DAAPService < MediaClientService
  def self.enable_setting
    :enable_daap
  end
end
