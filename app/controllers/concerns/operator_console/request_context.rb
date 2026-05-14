# frozen_string_literal: true

module OperatorConsole
  module RequestContext
    extend ActiveSupport::Concern

    included do
      around_action :with_operator_console_request_context
    end

    private

    def with_operator_console_request_context
      Current.user = current_user if respond_to?(:current_user)
      TenantContext.with_system_access { yield }
    ensure
      TenantContext.clear!
      Current.reset
    end
  end
end
