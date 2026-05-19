# frozen_string_literal: true

module OperatorConsole
  module RequestContext
    extend ActiveSupport::Concern

    included do
      prepend_around_action :with_operator_console_request_context
    end

    private

    def with_operator_console_request_context
      previous_account = Current.account
      previous_user = Current.user
      previous_bypass = TenantContext.bypass_enabled?

      TenantContext.apply_system_access!
      Current.user = current_user if respond_to?(:current_user)

      yield
    ensure
      Current.user = previous_user
      TenantContext.restore!(account: previous_account, bypass: previous_bypass)
    end
  end
end
