# frozen_string_literal: true

class MediaSyncingController < ApplicationController
  before_action :require_admin

  def create
    if scanning?
      flash[:alert] = t("error.syncing_in_progress")
      redirect_to setting_path
    else
      libraries_to_scan.each { |library| LibraryScanJob.perform_later(library.id) }
    end
  end

  private

  # A specific library can be targeted with `library_id`; otherwise every local
  # library is scanned, preserving the "sync everything" behavior of the legacy
  # whole-server sync button.
  def libraries_to_scan
    scope = Library.local
    params[:library_id].present? ? scope.where(id: params[:library_id]) : scope
  end

  # Report syncing status from the per-library `scan_state` column rather than
  # the global `Media.syncing?` cache flag (Req 2.6).
  def scanning?
    libraries_to_scan.syncing.exists?
  end
end
