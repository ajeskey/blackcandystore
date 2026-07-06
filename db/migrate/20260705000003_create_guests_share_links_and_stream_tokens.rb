class CreateGuestsShareLinksAndStreamTokens < ActiveRecord::Migration[8.1]
  def change
    # A Guest is a non-account participant admitted to a Party_Session or
    # Co_Listen_Session by opening a Share_Link (Req 5.1). Guest identity for
    # quota accounting and removal enforcement is the token to Guest binding
    # established at admission (Req 5.13).
    create_table :guests do |t|
      # Polymorphic owner: a Party_Session or Co_Listen_Session (Req 5.1).
      t.references :sessionable, polymorphic: true, null: false
      # Optional display name used for Shared_Playlist attribution (Req 5.12).
      t.string :display_name, null: true
      # Keyed digest of the Guest_Token only, never the plaintext (Req 8.7).
      # Bound at admission and used to resolve the bearer to this Guest (Req 5.13).
      t.string :guest_token_digest, null: false
      # When the Guest was admitted (Req 5.1).
      t.datetime :admitted_at
      # Set when the Guest is removed; subsequent requests are rejected (Req 5.8).
      t.datetime :removed_at, null: true
      # Running count of additions for per-Guest add-quota enforcement (Req 5.9).
      t.integer :add_count, null: false, default: 0
      # Start of the current add-rate accounting window; combined with add_count
      # to enforce the per-minute add rate without side effects on rejection
      # (Req 5.9).
      t.datetime :rate_window_started_at, null: true

      t.timestamps
    end

    # Fast, unique lookup of a Guest by its keyed token digest on every guest
    # request (Req 5.13). Unique because each Guest carries a distinct token.
    add_index :guests, :guest_token_digest, unique: true

    # A Share_Link is the joinable entry point for a session, backed by an
    # Access_Grant that carries the revocable, optionally-expiring credential
    # (Req 4.2, 8.1). Multi-library sessions model one grant per shared library.
    create_table :share_links do |t|
      # Polymorphic owner: a Party_Session or Co_Listen_Session (Req 4.2).
      t.references :sessionable, polymorphic: true, null: false
      # Backing Access_Grant supplying usable?/expires_at/revocation semantics
      # (Req 4.2, 4.4, 4.5, 4.6, 8.1, 8.5).
      t.references :access_grant, null: false, foreign_key: true

      t.timestamps
    end

    # A Stream_Token authenticates access to a Radio_Station's Shared_Stream via
    # a URL-embedded credential (Req 11.5). Only the keyed digest is persisted;
    # the token is rotatable and revocable. Co-listen stream tokens are NOT
    # stored here (they are derived per-participant from the Guest_Token).
    create_table :stream_tokens do |t|
      # Each station has at most one Stream_Token (has_one :stream_token), so the
      # reference is uniquely indexed.
      t.references :radio_station, null: false, foreign_key: true, index: { unique: true }
      # Keyed digest of the plaintext token only, never the plaintext (Req 8.7,
      # 11.5).
      t.string :token_digest, null: false
      # `active` or `revoked`; rotating/revoking invalidates the stream URL
      # (Req 11.5).
      t.string :status, null: false, default: "active"

      t.timestamps
    end

    # Fast, unique lookup of a Stream_Token by its keyed digest at connect time
    # (Req 11.5).
    add_index :stream_tokens, :token_digest, unique: true
  end
end
