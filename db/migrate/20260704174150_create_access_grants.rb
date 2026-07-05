class CreateAccessGrants < ActiveRecord::Migration[8.1]
  def change
    # Access_Grant lives on the hosting server. It authorizes a specific
    # redeemer to access a specific local Library and can be revoked (Req 4.1,
    # 7.2). The secret token is stored hashed (token_digest) and compared with a
    # constant-time comparison; the plaintext token only ever travels inside the
    # invite code.
    create_table :access_grants do |t|
      t.references :library, null: false, foreign_key: true
      t.string :token_digest, null: false
      # Set on local redemption (Req 5.1); nullable for cross-server redeemers.
      t.references :redeemer_user, foreign_key: { to_table: :users }, null: true
      # Opaque identifier of a remote redeeming server/user.
      t.string :redeemer_identity, null: true
      t.string :status, null: false, default: "active"
      t.datetime :expires_at
      # Redemption record; null until the grant is first redeemed (Req 5.1, 7.1).
      t.datetime :redeemed_at, null: true

      t.timestamps
    end

    # Fast lookup of a grant by its hashed token on every federation request
    # (Req 6.6). Unique because each grant carries a distinct secret token.
    add_index :access_grants, :token_digest, unique: true
  end
end
