# frozen_string_literal: true

# @spec POSTGRESQL-PERSISTENCE-001
# @spec POSTGRESQL-PERSISTENCE-006
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
      connection.select_value("SELECT NULLIF(current_setting($1, true), '')", "TenantContext#current_setting", setting_binds(key))
    rescue ActiveRecord::ConnectionNotEstablished
      nil
    rescue ActiveRecord::StatementInvalid => e
      raise unless transaction_aborted?(e)

      nil
    end

    def set_config(key, value)
      attempts = 0

      begin
        connection.exec_query("SELECT set_config($1, $2, false)", "TenantContext#set_config", setting_binds(key, value))
      rescue NoMethodError => error
        raise unless missing_postgresql_result?(error) && attempts.zero?

        attempts += 1
        retry
      rescue ActiveRecord::ConnectionNotEstablished
        nil
      rescue ActiveRecord::StatementInvalid => e
        raise unless transaction_aborted?(e)

        nil
      end
    end

    def transaction_aborted?(error)
      error.cause.is_a?(PG::InFailedSqlTransaction)
    end

    def missing_postgresql_result?(error)
      error.name == :cmd_tuples && error.message.include?("for nil")
    end

    def setting_binds(*values)
      values.map do |setting|
        ActiveRecord::Relation::QueryAttribute.new(nil, setting.to_s, ActiveRecord::Type::String.new)
      end
    end

    def connection
      ActiveRecord::Base.connection
    end
  end
end
