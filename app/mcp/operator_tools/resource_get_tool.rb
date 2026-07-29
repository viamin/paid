# frozen_string_literal: true

module OperatorTools
  class ResourceGetTool < BaseTool
    def self.description
      "Get a single #{resource_label} from the operator console."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          id: { type: "integer", description: "#{resource_label.titleize} ID" }
        },
        required: %w[id]
      }
    end

    def perform(id:)
      record = operator_policy_scope(self.class.model_class, policy_class: self.class.policy_class).find(id)

      self.class.attributes.index_with { |attribute| record.public_send(attribute) }
    end
  end
end
