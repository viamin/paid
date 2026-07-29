# frozen_string_literal: true

module OperatorTools
  class RecompressStyleGuides < BaseTool
    authorize :act_on?, ->(args) { style_guide_for(args.fetch(:style_guide_ids).first) }, policy_class: OperatorConsole::StyleGuidePolicy

    def self.tool_name = "operator_recompress_style_guides"
    def self.description = "Queue style guide recompression through the operator console workflow."
    def self.write_operation? = true

    def self.input_schema
      {
        type: "object",
        properties: {
          style_guide_ids: {
            type: "array",
            items: { type: "integer" },
            description: "One or more style guide IDs"
          },
          confirmed: { type: "boolean", description: "Must be true to execute this operator action" }
        },
        required: %w[style_guide_ids confirmed]
      }
    end

    def perform(style_guide_ids:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to execute this operator action" unless confirmed
      raise ArgumentError, "style_guide_ids must contain at least one ID" if style_guide_ids.blank?

      style_guides = Array(style_guide_ids).map { |id| style_guide_for(id) }
      action = Avo::Actions::RecompressStyleGuides.new.handle(
        query: style_guides,
        fields: {},
        current_user: user,
        resource: nil
      )

      message = Array(action.response[:messages]).last || {}
      {
        status: message[:type] == :success ? "ok" : "error",
        style_guide_ids: style_guides.map(&:id),
        message: message[:body]
      }
    end

    private

    def style_guide_for(style_guide_id)
      @style_guides_by_id ||= {}
      @style_guides_by_id[style_guide_id] ||= operator_policy_scope(StyleGuide, policy_class: OperatorConsole::StyleGuidePolicy).find(style_guide_id)
    end
  end
end
