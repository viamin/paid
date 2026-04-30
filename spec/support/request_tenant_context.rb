# frozen_string_literal: true

module RequestTenantContext
  def process(...)
    super.tap do
      next if RSpec.current_example.metadata[:tenant_isolation]

      TenantContext.apply_system_access!
    rescue ActiveRecord::ConnectionNotEstablished
      # Some request specs intentionally simulate a dead database connection.
      # In that case there is no session state to restore for the next query.
    end
  end
end

ActionDispatch::Integration::Session.prepend(RequestTenantContext)
