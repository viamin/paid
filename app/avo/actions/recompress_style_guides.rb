# frozen_string_literal: true

class Avo::Actions::RecompressStyleGuides < Avo::BaseAction
  self.name = "Recompress Style Guides"

  def handle(query:, current_user:, **)
    return error("Select at least one style guide.") if query.empty?

    query.each do |style_guide|
      StyleGuides::EnqueueCompression.call(
        style_guide: style_guide,
        initiated_by: current_user,
        source: "operator_console"
      )
    end

    succeed(success_message(query.count))
  end

  private

  def success_message(count)
    noun = "style guide".pluralize(count)
    "Queued recompression for #{count} #{noun}."
  end
end
