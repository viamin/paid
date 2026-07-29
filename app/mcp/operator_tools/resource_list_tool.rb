# frozen_string_literal: true

module OperatorTools
  class ResourceListTool < BaseTool
    DEFAULT_LIMIT = 20

    def self.description
      "List #{resource_label.pluralize} from the operator console."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          limit: { type: "integer", description: "Max results (default 20)", default: DEFAULT_LIMIT }
        }
      }
    end

    def perform(limit: DEFAULT_LIMIT)
      records.limit(limit.to_i.clamp(1, 100)).map { |record| serialize(record) }
    end

    private

    def records
      operator_policy_scope(self.class.model_class.order(order_clause), policy_class: self.class.policy_class)
    end

    def order_clause
      self.class.respond_to?(:order_clause) ? self.class.order_clause : { id: :desc }
    end

    def serialize(record)
      self.class.attributes.index_with { |attribute| record.public_send(attribute) }
    end
  end
end
