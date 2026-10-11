# frozen_string_literal: true

module Tools
  # @spec ONBOARD-CHAT-009
  class GetProductDocs < BaseTool
    authorize :show?, ->(_args) { current_user.account }, policy_class: ApplicationPolicy

    def self.tool_name = "get_product_docs"
    def self.description = "Search Paid's curated product documentation by topic or words."

    def self.input_schema
      { type: "object", properties: { topic: { type: "string" }, query: { type: "string" } } }
    end

    def perform(topic: nil, query: nil)
      documents = YAML.load_file(Rails.root.join("config/onboarding_product_docs.yml"))
      needle = [ topic, query ].compact.join(" ").downcase
      documents.filter_map do |id, document|
        next unless needle.blank? || [ id, document["title"], document["content"] ].join(" ").downcase.include?(needle)

        document.merge("topic" => id)
      end
    end
  end
end
