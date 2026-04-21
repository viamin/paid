# frozen_string_literal: true

class TenantContext
  class << self
    def apply!(account)
      Current.account = account
      set_config("paid.current_account_id", account&.id)
      set_config("paid.bypass_tenant_rls", false)
    end

    def clear!
      Current.account = nil
      set_config("paid.current_account_id", nil)
      set_config("paid.bypass_tenant_rls", false)
    end

    def with(account)
      previous_account = Current.account
      apply!(account)
      yield
    ensure
      previous_account ? apply!(previous_account) : clear!
    end

    def with_system_access
      previous_account = Current.account
      previous_account_id = current_setting("paid.current_account_id")
      previous_bypass = current_setting("paid.bypass_tenant_rls")

      Current.account = nil
      set_config("paid.current_account_id", nil)
      set_config("paid.bypass_tenant_rls", true)
      yield
    ensure
      Current.account = previous_account
      set_config("paid.current_account_id", previous_account_id)
      set_config("paid.bypass_tenant_rls", previous_bypass)
    end

    private

    def current_setting(key)
      connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT NULLIF(current_setting(?, true), '')", key ])
      )
    end

    def set_config(key, value)
      connection.execute(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT set_config(?, ?, false)", key, value.to_s ])
      )
    end

    def connection
      ActiveRecord::Base.connection
    end
  end
end
