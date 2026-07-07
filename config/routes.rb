Rails.application.routes.draw do
  root "home#index"

  resources :sessions, only: [ :new, :create ]
  resource :setting, only: [ :show, :update ]
  # Read/update the current User's Source_Preference (Req 11.3, 11.10). A
  # singular resource because the value always applies to Current.user.
  resource :source_preference, only: [ :show, :update ]
  # Read/select the current User's Playback_Mode from either the Web_Player or
  # the App_Player (Req 16.2, 16.3). A singular resource because the mode always
  # applies to Current.user. `update` records the mode and enforces the
  # mode-exclusivity invariant (Req 18.1; Property 21).
  resource :playback_mode, only: [ :show, :update ]
  # The singular /library route is the Active_Library overview dashboard. It is
  # named `library_overview` so the canonical `library` helper is free for the
  # plural resource's member routes (show a specific library / rename / delete).
  resource :library, only: [ :show ], as: :library_overview
  # Select which Library the current User is browsing (their Active_Library,
  # Req 3.1). Available to any User for a Library they are authorized to access.
  resource :active_library, only: [ :update ]
  resources :libraries, only: [ :index, :new, :create, :edit, :update, :destroy ] do
    # Owner-only listing of a Local_Library's Access_Grants (Req 7.1, 7.5).
    resources :access_grants, only: [ :index ]
  end
  # Disconnect a Remote_Library the current User reached by redeeming an invite.
  # Destroying the Library_Connection tears down its Catalog_Mirror in full
  # (Req 9.3). Scoped to Current.user so a User can only remove their own
  # connections.
  resources :library_connections, only: [ :destroy ]
  resource :system, only: [ :show ]

  # Bookkeeping for the current User's client-side Cast_Session under the
  # `client_cast` Playback_Mode (Req 17, 18.2). A singular resource because the
  # session always belongs to Current.user. `create` selects the target
  # Output_Device / current Song; the member actions drive the Cast_Session
  # state machine (Req 17.5, 17.6, 17.7, 17.16). The actual casting to the device
  # happens on the client.
  resource :cast_session, only: [ :show, :create ] do
    post :play
    post :resume
    post :pause
    post :stop
  end

  # The Output_Devices discovered on the local network (Req 13). `index` runs a
  # Device_Discovery cycle and lists the currently reachable AirPlay/Chromecast
  # targets, degrading to an empty set when the playback sidecar is absent
  # (Req 13.5). This is the browser-facing device picker / cast-control hub for
  # the `client_cast` Playback_Mode.
  resources :output_devices, only: [ :index ]

  # --- Radio Stations, Party & Co-listen Modes (radio-party-colisten spec) ---
  # The client-agnostic JSON + Hotwire API_Surface for the three social-listening
  # capabilities (Req 9.1). Each controller answers both `format.html` (Turbo) and
  # `format.json` under identical authorization (Req 9.4, 9.5).

  # Radio_Station configuration + lifecycle (Req 1, 9.1, 10, 11). CRUD plus:
  # start/stop drive the Station_State machine (Req 10.1, 10.2); rotate/revoke
  # manage the station's keyed-digest Stream_Token (Req 11.5). The member
  # `stream` route is the station's Stream_Endpoint: it exists for every station
  # regardless of state (Req 9.6) and accepts the `.mp3` extension used by generic
  # Icecast/SHOUTcast clients, but audio is delivered only while `started`
  # (Req 3.6) — served by StreamEndpointController (task 9.4).
  resources :radio_stations do
    member do
      post :start
      post :stop
      post :rotate_stream_token
      post :revoke_stream_token
      get :stream, to: "stream_endpoint#radio_station"
    end
  end

  # Co_Listen_Session — the shared, always-on collaborative stream (Req 7, 9.1,
  # 10.7, 10.8). CRUD plus activate/deactivate (Session_State machine) and
  # share-link generation for admitting Guests. Like a Radio_Station it exposes a
  # Stream_Endpoint for every session regardless of state (Req 9.6), delivering
  # audio only while `active`; a co-listen stream is never public and is
  # authorized by a guest-derived Stream_Token (Req 11.8, 11.9). Guests
  # contribute to the session's Shared_Playlist through nested
  # shared_playlist_entries (add/remove/reorder).
  resources :co_listen_sessions do
    member do
      post :activate
      post :deactivate
      post :generate_share_link
      get :stream, to: "stream_endpoint#co_listen_session"
    end
  end

  # Shared_Playlist contribution surface (Req 5.2, 6.6, 9.1). A Party_Session
  # and a Co_Listen_Session each own a Shared_Playlist (polymorphic), so entries
  # are nested under the Shared_Playlist itself (`shared_playlist_id`) rather
  # than under either session kind, matching SharedPlaylistEntriesController's
  # lookup. The Host and admitted Guests add (`create`), remove (`destroy`), and
  # reorder (`update` — reposition an entry) individual Songs; `index` lists the
  # playlist in order.
  resources :shared_playlists, only: [] do
    resources :shared_playlist_entries, only: [ :index, :create, :update, :destroy ]
  end

  # Party_Session — a host shares a link and Guests add Songs to a Shared_Playlist
  # that streams to host-selected Output_Devices (Req 4, 6, 9.1). CRUD plus
  # share-link generation and revocation (Req 4.2, 4.6), host-only device
  # selection (Req 6.2) and host-only transport control — stop/pause/skip
  # (Req 6.5, 6.8). A Party_Session deliberately exposes NO Stream_Endpoint,
  # because it plays to devices rather than per-Listener streams (Req 9.7).
  resources :party_sessions do
    member do
      post :generate_share_link
      post :revoke
      post :select_output_devices
      post :stop
      post :pause
      post :skip
    end
  end

  # Guest join via a Share_Link (Req 5.1, 5.2, 9.2). Opening the link shows the
  # join page; POSTing admits the Guest (if the backing Access_Grant is usable and
  # the session has capacity) and issues a non-cookie Bearer Guest_Token bound to
  # the new Guest record.
  get "join/:token", to: "share_link_redemptions#show", as: :guest_join
  post "join/:token", to: "share_link_redemptions#create", as: :guest_admit

  # Sharing endpoints. Generating an invite is owner-only (enforced by
  # InviteManager.generate — Req 4.6); redeeming a code is available to any
  # authenticated User (Req 5.1). Revoking an Access_Grant is owner-only
  # (enforced by InviteManager.revoke — Req 7.2, 7.5).
  resources :invites, only: [ :create ]
  resources :redemptions, only: [ :new, :create ]
  resources :access_grants, only: [ :destroy ]

  resources :artists, only: [ :index, :show, :update ]
  resources :songs, only: [ :index, :show ] do
    # The current User's Playback_Position for this Song, read/written by the
    # Web_Player and App_Player (Req 6.2, 6.5, 8.1). A singular nested resource
    # because the record always belongs to Current.user, so there is exactly one
    # per (User, Song) pair and no id is needed.
    resource :playback_position, only: [ :show, :update ], module: :songs
  end
  # The current User's Continue_Listening_List, exposed as a client-agnostic
  # representation for App_Players (Req 8.1, 8.2). A singular resource because
  # the list always belongs to Current.user; the Home page renders the same list
  # server-side. An empty result is a valid empty list (Req 4.7).
  resource :continue_listening, only: [ :show ], controller: :continue_listening
  resources :albums, only: [ :index, :show, :update ]

  resources :users, except: [ :show ] do
    resource :setting, only: [ :update ], module: "users"
  end

  resources :playlists, only: [ :index, :create, :update, :destroy ] do
    resources :songs, only: [ :index, :create, :destroy ], module: "playlists" do
      delete "/", action: :destroy_all, on: :collection
      put "move", on: :member
    end
  end

  namespace :current_playlist do
    resources :songs, only: [ :index, :create, :destroy ] do
      put "move", on: :member

      collection do
        delete "/", action: :destroy_all
        resources :albums, only: :update, module: :songs
        resources :playlists, only: :update, module: :songs
      end
    end
  end

  namespace :favorite_playlist do
    resources :songs, only: [ :index, :create, :destroy ] do
      delete "/", action: :destroy_all, on: :collection
      put "move", on: :member
    end
  end

  namespace :dialog do
    resources :playlists, only: [ :index, :new, :edit ]
    resources :artists, only: [ :edit ]
    resources :albums, only: [ :edit ]
  end

  get "/search", to: "search#index", as: "search"

  namespace :search do
    resources :artists, only: [ :index ]
    resources :songs, only: [ :index ]
    resources :albums, only: [ :index ]
    resources :playlists, only: [ :index ]
  end

  namespace :albums do
    namespace :filter do
      resources :genres, only: [ :index ]
      resources :years, only: [ :index ]
    end
  end

  namespace :songs do
    namespace :filter do
      resources :genres, only: [ :index ]
      resources :years, only: [ :index ]
    end
  end

  namespace :my do
    resource :session, only: [ :destroy ]
    resource :profile, only: [ :edit, :update ]
  end

  # Same-origin proxy for streaming a Song that lives in a Remote_Library
  # (Req 6.2, 6.3, 8.5). The redeeming server fetches the audio from the hosting
  # server through the Song's Library_Connection, keeping the Access_Grant
  # credential server-side, and forwards the bytes to the player. This matches
  # the path produced by `PathResolver#resolve_stream` (`/stream/remote/:song_id`).
  get "stream/remote/:song_id", to: "remote_stream#show", as: :remote_stream

  # Same-origin proxy for a Remote_Library's cover image (Req 7.4, 1.4). The
  # redeeming server loads the mirrored Album/Artist, reads its stored
  # hosting-side id (`remote_album_id`/`remote_artist_id`), and fetches the
  # artwork bytes live from the hosting server through the Library_Connection —
  # no artwork bytes are stored. This matches the path produced by
  # `PathResolver#resolve_asset` (`/asset/remote/:type/:id`, where `:type` is
  # "albums" or "artists" and `:variant` is an optional query param).
  get "asset/remote/:type/:id", to: "remote_asset#show", as: :remote_asset

  # Redeeming-side Nudge_Endpoint (Req 6.2, 6.5). A hosting Server POSTs a
  # best-effort Catalog_Nudge here (`{ nudge_token }`) after bumping its
  # Catalog_Version so the redeemer can pull sooner than its next scheduled
  # sync. This is the top-level `/nudges` path the redeemer registers as its
  # `nudge_callback_url` (its base URL + "/nudges") at redemption. Like the
  # federation endpoints it is token-authenticated server-to-server, so the
  # controller inherits from ActionController::API and uses no session auth/CSRF.
  post "nudges", to: "nudges#create"

  resources :stream, only: [ :new ]
  resources :transcoded_stream, only: [ :new ]

  # Cross-server (federation) API. These endpoints are called by a remote
  # redeeming Server and are authenticated with an Access_Grant token presented
  # as `Authorization: Bearer <token>` rather than the app's normal session
  # auth. Each content endpoint serves only local, authorized content.
  namespace :federation do
    get "ping", to: "ping#show", as: :ping
    post "grants/confirm", to: "grants#confirm", as: :grants_confirm

    get "libraries/:library_id/songs", to: "libraries#songs", as: :library_songs
    get "libraries/:library_id/albums", to: "libraries#albums", as: :library_albums
    get "libraries/:library_id/artists", to: "libraries#artists", as: :library_artists

    # Changes_Since_API: ordered Catalog_Changes after a Sync_Cursor plus the
    # Catalog_Version to adopt, so a redeeming Server pulls only what changed
    # (Req 3.2). `?cursor=<int>&page=<int>` selects the delta page.
    get "libraries/:library_id/changes", to: "changes#index", as: :library_changes

    get "libraries/:library_id/songs/:song_id/stream", to: "songs#stream", as: :library_song_stream

    get "libraries/:library_id/albums/:id/asset", to: "assets#show", as: :library_album_asset, defaults: { record_type: "albums" }
    get "libraries/:library_id/artists/:id/asset", to: "assets#show", as: :library_artist_asset, defaults: { record_type: "artists" }
  end

  resource :media_syncing, only: [ :create ]

  get "/403", to: "errors#forbidden", as: :forbidden
  get "/404", to: "errors#not_found", as: :not_found
  get "/422", to: "errors#unprocessable_entity", as: :unprocessable_entity
  get "/500", to: "errors#internal_server_error", as: :internal_server_error

  get "up", to: "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/*
  get "service-worker", to: "rails/pwa#service_worker", as: :pwa_service_worker
  get "manifest", to: "rails/pwa#manifest", as: :pwa_manifest
end
