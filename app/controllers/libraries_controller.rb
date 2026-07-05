# frozen_string_literal: true

class LibrariesController < ApplicationController
  # Pull in the Library_Access_Controller browsing helpers so the library list
  # is computed with the same authorization rules used everywhere else
  # (owned local libraries + active remote connections).
  include LibraryAccess

  # Creating, renaming, and deleting a Local_Library is restricted to the
  # Server_Owner. `require_admin` raises BlackCandy::Forbidden for non-admins
  # (and in demo mode), so any create/modify request from a User who is not a
  # Server_Owner is rejected with an authorization error (Req 1.8).
  before_action :require_admin, only: [ :new, :create, :edit, :update, :destroy ]
  before_action :find_library, only: [ :edit, :update, :destroy ]

  def show
    # Counts reflect only the current User's Active_Library so the library
    # overview lists content scoped to what the User is browsing, and shows
    # zero when the User has access to no libraries (Req 3.2, 3.7).
    @albums_count = scoped_to_active_library(Album).count
    @artists_count = scoped_to_active_library(Artist).count
    @songs_count = scoped_to_active_library(Song).count
    @playlists_count = Current.user.playlists_with_favorite.count
    @scanning = Library.scanning?
  end

  # Lists every Library the current User can reach and, alongside that list,
  # the content of the User's current Active_Library.
  #
  # The list is every Local_Library the User owns together with every
  # Remote_Library reached through an active Library_Connection (Req 3.4);
  # `authorized_libraries` (from LibraryAccess) computes exactly that set, so a
  # User with access to zero libraries gets an empty list. The response also
  # carries the content of the current Active_Library — albums, artists, and
  # songs scoped through `scoped_to_active_library` so it stays restricted to
  # what the User is browsing (Req 3.8).
  def index
    @libraries = authorized_libraries(Current.user).includes(:library_connection).order(:name)
    @active_library = Current.user&.active_library

    @albums = scoped_to_active_library(Album).includes(:artist).with_attached_cover_image
    @artists = scoped_to_active_library(Artist).with_attached_cover_image
    @songs = scoped_to_active_library(Song).includes(:artist, :album)
  end

  # Render the new-library form (Server_Owner only).
  def new
    @library = Library.new
  end

  # Render the rename form for an existing Local_Library (Server_Owner only).
  def edit
  end

  # Create a Local_Library owned by the current Server_Owner from the submitted
  # name, media path, and kind. The Library model validates the name (present,
  # 1–255 chars, unique) and, for local libraries, that the media path exists
  # and is readable; `save!` surfaces those validation errors through the
  # standard RecordInvalid handling (Req 1.1, and validation for 1.3, 1.4, 1.9,
  # 1.10, 1.11).
  def create
    @library = Library.new(library_params)
    @library.owner = Current.user
    @library.save!

    @active_library = Current.user&.active_library

    respond_to do |format|
      format.html { redirect_to libraries_path, notice: t("notice.created") }
      format.json { render partial: "libraries/library", locals: { library: @library }, status: :created }
    end
  end

  # Rename a Local_Library. Only the name is updated, so the Library's existing
  # content associations (songs, albums, artists) are preserved (Req 1.5). The
  # same name validations apply, and an invalid name leaves the Library
  # unchanged via `update!` raising RecordInvalid (Req 1.9, 1.10).
  def update
    @library.update!(library_rename_params)

    @active_library = Current.user&.active_library

    respond_to do |format|
      format.html { redirect_to libraries_path, notice: t("notice.updated") }
      format.json { render partial: "libraries/library", locals: { library: @library } }
    end
  end

  # Delete a Local_Library. Destroying the record triggers the model's deletion
  # cascade, which removes the Library's songs, cleans up albums/artists that no
  # longer have any song, and deletes the Library's Access_Grants (Req 1.6, 2.4,
  # 2.5).
  def destroy
    @library.destroy

    respond_to do |format|
      format.html { redirect_to libraries_path, notice: t("notice.deleted") }
      format.json { head :no_content }
    end
  end

  private

  def find_library
    @library = Library.find(params[:id])
  end

  def library_params
    params.require(:library).permit(:name, :media_path, :kind)
  end

  def library_rename_params
    params.require(:library).permit(:name)
  end
end
