# frozen_string_literal: true

module OperatorTools
  class BaseTool < Tools::BaseTool
    def self.available_to?(user:)
      user&.operator? == true
    end

    def self.available_for_chat?(user:, session:)
      available_to?(user:)
    end

    def dispatch(**args)
      raise Tools::UnauthorizedError, "Tool calls require an authenticated user" if user.blank?

      previous_account = Current.account
      previous_user = Current.user
      previous_bypass = TenantContext.bypass_enabled?

      TenantContext.apply_system_access!
      Current.user = user

      reset_authorization_tracking!
      run_declared_authorizations!(args)
      raise Tools::UnauthorizedError, "#{self.class.tool_name} must authorize before execution" unless preflight_authorized?

      perform(**args)
    ensure
      Current.user = previous_user
      TenantContext.restore!(account: previous_account, bypass: previous_bypass)
    end

    private

    def operator_policy_scope(scope, policy_class:)
      policy_scope(scope, policy_scope_class: policy_class::Scope)
    end
  end
end
