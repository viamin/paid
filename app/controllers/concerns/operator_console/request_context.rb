# frozen_string_literal: true

module OperatorConsole
  module RequestContext
    extend ActiveSupport::Concern

    included do
      prepend_before_action :apply_operator_console_request_context
      after_action :clear_operator_console_request_context
    end

    private

    def apply_operator_console_request_context
      TenantContext.apply_system_access!
      Current.user = current_user if respond_to?(:current_user)
    end

    def clear_operator_console_request_context
      TenantContext.clear!
      Current.reset
    end
  end
end
