# Sharing

Black Candy libraries can be shared across servers with invite codes. A library owner mints an **invite code** scoped to a single local library, hands it to another person, and that person **redeems** it to gain access. When the code points at a library on the current server, redeeming records a local access grant. When it points at a library on a different server, redeeming establishes a `Library_Connection` to the remote server after the issuing server confirms the grant, and materializes a metadata-only catalog mirror of the remote library that then keeps itself in sync automatically.

An invite code is a single opaque string (Base64URL, unpadded) that encodes the issuing server's base URL and a 128-bit secret token. Treat it as a credential: anyone holding it can redeem it until it expires or is revoked.

Generating invites and viewing or revoking access grants are **owner-only**. A request from a user who does not own the target library is rejected with `403 Forbidden`. Redeeming a code is available to any authenticated user.

All error responses share the shape used elsewhere in the API:

```json
{ "type": "Malformed", "message": "invite code could not be decoded: ..." }
```

## `POST /invites`

Generates an invite code scoped to one local library the current user owns. Owner-only. On success the encoded invite code is returned; no other record is exposed.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `library_id` | integer | Yes | The local library to share. Must exist on this server and be owned by the current user. |
| `expires_in` | integer | No | Time until the code expires, in **seconds**. Must be between 1 minute (`60`) and 365 days (`31536000`) inclusive. Defaults to 7 days when omitted. |

__Response:__ `201 Created`

```json
{
  "invite_code": "eyJ1IjoiaHR0cHM6Ly9ibGFja2NhbmR5LmV4YW1wbGUuY29tIiwidCI6IjRmM2E5YjJjMWQ4ZTdmNjA1YTRiM2MyZDFlMGY5YThiIn0"
}
```

__Errors:__

| Status | `type` | When |
|--------|--------|------|
| `403 Forbidden` | `Forbidden` | The current user does not own the library. No access grant is created. |
| `404 Not Found` | `LibraryNotFound` | The library is not a local library on this server. |
| `404 Not Found` | `RecordNotFound` | No library exists for `library_id`. |
| `422 Unprocessable Entity` | `InvalidExpiration` | `expires_in` is shorter than 1 minute or longer than 365 days. |

## `POST /redemptions`

Redeems an invite code for the current user. Any authenticated user may redeem.

The decoded issuing server URL determines the path:

- **Local redemption** — the code references a library on this server. The current user is granted access and the redemption is recorded against the access grant. Redeeming again with the same non-revoked code by the same user is idempotent and still reports success, even after the code has expired.
- **Cross-server redemption** — the code references a library on another server. This server asks the issuing server to confirm the grant within 30 seconds. On confirmation a single `Library_Connection` to the remote library is created (reused if one already exists for the same user, server, and remote library) and a full catalog mirror sync of the remote library is triggered. The mirror stores metadata only and thereafter keeps itself in sync automatically.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `invite_code` | string | Yes | The invite code to redeem. |

__Response (local redemption):__ `201 Created`

```json
{
  "library": {
    "id": 1,
    "name": "Jazz Collection"
  }
}
```

__Response (cross-server redemption):__ `201 Created`

```json
{
  "connection": {
    "id": 7,
    "server_base_url": "https://remote.example.com",
    "remote_library_id": 3,
    "status": "active"
  }
}
```

__Errors:__

| Status | `type` | When |
|--------|--------|------|
| `422 Unprocessable Entity` | `Malformed` | The code cannot be decoded into a server URL and secret token. Existing access is left unchanged. |
| `403 Forbidden` | `Expired` | First-time redemption of a code whose expiration is in the past. |
| `403 Forbidden` | `Revoked` | The grant has been revoked, the token matches no grant, or (cross-server) the issuing server reports the grant invalid or revoked. No `Library_Connection` is created. |
| `503 Service Unavailable` | `ServerUnavailable` | (Cross-server) the issuing server is unreachable or did not confirm within 30 seconds. No `Library_Connection` is created. |

## `GET /libraries/:library_id/access_grants`

Lists every access grant for a local library the current user owns, each with its redemption status and expiration. Owner-only. Returns an empty `access_grants` array when the library has no grants.

__Response:__ `200 OK`

```json
{
  "access_grants": [
    {
      "id": 42,
      "library_id": 1,
      "status": "active",
      "redeemer_user_id": 8,
      "redeemed_at": "2026-07-01T12:34:56.000Z",
      "expires_at": "2026-07-08T12:34:56.000Z"
    },
    {
      "id": 43,
      "library_id": 1,
      "status": "revoked",
      "redeemer_user_id": null,
      "redeemed_at": null,
      "expires_at": "2026-07-10T09:00:00.000Z"
    }
  ]
}
```

`status` is either `active` or `revoked`. `redeemer_user_id` and `redeemed_at` are `null` until the grant is redeemed by a local user (cross-server redeemers are recorded on the issuing server without a local user id).

__Errors:__

| Status | `type` | When |
|--------|--------|------|
| `403 Forbidden` | `Forbidden` | The current user does not own the library; none of its grants are returned. |
| `404 Not Found` | `RecordNotFound` | No library exists for `library_id`. |

## `DELETE /access_grants/:id`

Revokes a single access grant on behalf of its library's owner. Owner-only. Revocation is terminal: once a grant is `revoked` it stays revoked, future redemptions of its invite code are rejected, and the redeemer's mirror of the shared library is torn down on their next sync. Revoking an already-revoked grant reports success without further change. Only the identified grant is affected; every other grant for the same library is left unchanged.

__Response:__ `200 OK`

```json
{
  "id": 42,
  "library_id": 1,
  "status": "revoked",
  "redeemer_user_id": 8,
  "redeemed_at": "2026-07-01T12:34:56.000Z",
  "expires_at": "2026-07-08T12:34:56.000Z"
}
```

__Errors:__

| Status | `type` | When |
|--------|--------|------|
| `403 Forbidden` | `Forbidden` | The current user does not own the grant's library; the grant is left unchanged. |
| `404 Not Found` | `GrantNotFound` | No access grant exists for `id`. |
