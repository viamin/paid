# frozen_string_literal: true

module Tools
  class GetTenantSettings < BaseTool
    authorize :update?, ->(_args) { account }, policy_class: AccountPolicy

    def self.tool_name = "get_tenant_settings"

    def self.description
      "Read tenant settings for the current account."
    end

    def self.available_to?(user:)
      policy_allows?(user:, record: user&.account, query: :update?, policy_class: AccountPolicy)
    end

    def perform
      account.tenant_setting!.attributes.except("id", "account_id", "created_at", "updated_at", "log_data")
    end
  end
end
