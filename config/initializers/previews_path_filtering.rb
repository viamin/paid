# frozen_string_literal: true

require "action_dispatch/http/filter_parameters"

module PreviewPathFiltering
  PREVIEW_TOKEN_SEGMENT = %r{\A(/previews/)([^/?#]+)(?=/)}.freeze

  def filtered_path
    redact_preview_token(super)
  end

  private

  def redact_preview_token(path)
    path.to_s.sub(PREVIEW_TOKEN_SEGMENT, "\\1[FILTERED]")
  end
end

ActionDispatch::Http::FilterParameters.prepend(PreviewPathFiltering)
