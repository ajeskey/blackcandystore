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

  # Sharing endpoints. Generating an invite is owner-only (enforced by
  # InviteManager.generate — Req 4.6); redeeming a code is available to any
  # authenticated User (Req 5.1). Revoking an Access_Grant is owner-only
  # (enforced by InviteManager.revoke — Req 7.2, 7.5).
  resources :invites, only: [ :create ]
  resources :redemptions, only: [ :create ]
  resources :access_grants, only: [ :destroy ]

  resources :artists, only: [ :index, :show, :update ]
  resources :songs, only: [ :index, :show ]
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
