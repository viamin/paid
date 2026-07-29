# frozen_string_literal: true

module OperatorTools
  class GetStyleGuide < ResourceGetTool
    authorize :show?, ->(args) { StyleGuide.find(args.fetch(:id)) }, policy_class: OperatorConsole::StyleGuidePolicy

    def self.tool_name = "operator_get_style_guide"
    def self.model_class = StyleGuide
    def self.policy_class = OperatorConsole::StyleGuidePolicy
    def self.resource_label = "style guide"
    def self.attributes = %i[id name account_id project_id language active created_at updated_at]
  end
end
