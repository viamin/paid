# frozen_string_literal: true

class TenantContext
  class << self
    def apply!(account)
      Current.account = account
      set_config("paid.current_account_id", account&.id)
      set_config("paid.bypass_tenant_rls", false)
    end

    def apply_system_access!
      Current.account = nil
      set_config("paid.current_account_id", nil)
      set_config("paid.bypass_tenant_rls", true)
    end

    def clear!
      Current.account = nil
      set_config("paid.current_account_id", nil)
      set_config("paid.bypass_tenant_rls", false)
    end

    def bypass_enabled?
      ActiveModel::Type::Boolean.new.cast(current_setting("paid.bypass_tenant_rls"))
    end

    def restore!(account:, bypass:)
      return apply_system_access! if ActiveModel::Type::Boolean.new.cast(bypass)
      return apply!(account) if account

      clear!
    end

    def with(account)
      previous_account = Current.account
      previous_account_id = current_setting("paid.current_account_id")
      previous_bypass = current_setting("paid.bypass_tenant_rls")

      apply!(account)
      yield
    ensure
      Current.account = previous_account
      set_config("paid.current_account_id", previous_account_id)
      set_config("paid.bypass_tenant_rls", previous_bypass)
    end

    def with_system_access
      previous_account = Current.account
      previous_account_id = current_setting("paid.current_account_id")
      previous_bypass = current_setting("paid.bypass_tenant_rls")

      apply_system_access!
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
    rescue ActiveRecord::StatementInvalid => e
      raise unless transaction_aborted?(e)

      nil
    end

    def set_config(key, value)
      connection.execute(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT set_config(?, ?, false)", key, value.to_s ])
      )
    rescue ActiveRecord::StatementInvalid => e
      raise unless transaction_aborted?(e)

      nil
    end

    def transaction_aborted?(error)
      error.cause.is_a?(PG::InFailedSqlTransaction)
    end

    def connection
      ActiveRecord::Base.connection
    end
  end
end
