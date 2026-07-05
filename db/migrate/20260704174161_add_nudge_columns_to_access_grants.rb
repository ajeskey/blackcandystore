class AddNudgeColumnsToAccessGrants < ActiveRecord::Migration[8.1]
  def change
    # Best-effort Catalog_Nudge registration recorded on the hosting side at
    # redemption (Req 6.1). Both columns are additive and nullable so existing
    # Access_Grants are untouched and a grant without a registered callback
    # simply relies on the redeemer's scheduled pull backbone.

    # The redeemer's own Nudge_Endpoint URL (its base URL + "/nudges") that the
    # host POSTs to when the shared library's catalog changes. Null when the
    # redeemer did not register a callback (Req 6.1).
    add_column :access_grants, :nudge_callback_url, :string, null: true

    # The opaque per-connection token the redeemer generated at redemption. The
    # host echoes it back in the nudge body so the redeemer can map the nudge to
    # the correct Library_Connection (Req 6.5). Null when unregistered.
    add_column :access_grants, :nudge_token, :string, null: true
  end
end
