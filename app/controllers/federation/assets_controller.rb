# frozen_string_literal: true

module Federation
  # Serves the cover image bytes of an Album or Artist in an authorized local
  # library to a remote redeeming Server (Req 9.4, 9.6). The owning record is
  # scoped strictly to the authorized local library. When the record has no
  # cover image the endpoint answers 404 so the redeeming Server can resolve the
  # asset as absent (Req 9.7).
  class AssetsController < BaseController
    VARIANTS = %i[small medium large].freeze

    def show
      authorize_federation!(params[:library_id])

      record = record_class.where(library_id: @library.id).find(params[:id])

      unless record.has_cover_image?
        head :not_found
        return
      end

      image = resolve_image(record.cover_image)
      send_data image.download, type: image.content_type, disposition: "inline"
    end

    private

    # The requested asset variant (small/medium/large) processed for delivery,
    # or the original attachment when no valid variant is requested.
    def resolve_image(cover_image)
      variant = params[:variant].presence&.to_sym

      if variant && VARIANTS.include?(variant)
        cover_image.variant(variant).processed
      else
        cover_image
      end
    end

    def record_class
      case params[:record_type]
      when "albums" then Album
      when "artists" then Artist
      else
        raise BlackCandy::Forbidden
      end
    end
  end
end
