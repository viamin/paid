# frozen_string_literal: true

module OperatorTools
  class OperatorConsoleInventory < BaseTool
    def self.tool_name = "operator_console_inventory"

    def self.description
      "List the operator-only Avo resources and actions currently mirrored into chat tools."
    end

    def perform
      {
        operator_check: "User#operator?",
        resources: Inventory::RESOURCES,
        unsupported_preliminary_surfaces: Inventory::PRELIMINARY_SURFACES_NOT_IN_AVO
      }
    end
  end
end
