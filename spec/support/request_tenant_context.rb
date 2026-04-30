# frozen_string_literal: true

module RequestTenantContext
  def process(...)
    super.tap do
      next if RSpec.current_example.metadata[:tenant_isolation]

      TenantContext.apply_system_access!
    end
  end
end

ActionDispatch::Integration::Session.prepend(RequestTenantContext)
