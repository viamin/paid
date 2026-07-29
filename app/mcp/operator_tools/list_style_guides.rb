# frozen_string_literal: true

module OperatorTools
  class ListStyleGuides < ResourceListTool
    authorize :index?, ->(_args) { StyleGuide.new }, policy_class: OperatorConsole::StyleGuidePolicy

    def self.tool_name = "operator_list_style_guides"
    def self.model_class = StyleGuide
    def self.policy_class = OperatorConsole::StyleGuidePolicy
    def self.resource_label = "style guide"
    def self.attributes = %i[id name account_id project_id language active created_at updated_at]
    def self.order_clause = { updated_at: :desc }
  end
end
