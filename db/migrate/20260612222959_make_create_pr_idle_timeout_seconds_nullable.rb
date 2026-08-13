# frozen_string_literal: true

class MakeCreatePrIdleTimeoutSecondsNullable < ActiveRecord::Migration[8.1]
  def up
    # Allow NULL so that nil unambiguously means "use system default" rather
    # than relying on a magic sentinel value (360) that cannot be distinguished
    # from a user who deliberately chose 360 s.
    safety_assured do
      change_column_null :user_settings, :create_pr_idle_timeout_seconds, true
      change_column_default :user_settings, :create_pr_idle_timeout_seconds, nil
    end

    # Existing 360-valued rows were set by the DB default, not by explicit user
    # choice, so reset them to nil so they pick up per-runner tuned defaults.
    # There is no way to distinguish "user set 360" from "DB default 360" in
    # historical data, so all 360 values are treated as legacy defaults here.
    UserSetting.where(create_pr_idle_timeout_seconds: 360).update_all(create_pr_idle_timeout_seconds: nil) # rubocop:disable Rails/SkipsModelValidations
  end

  def down
    UserSetting.where(create_pr_idle_timeout_seconds: nil).update_all(create_pr_idle_timeout_seconds: 360) # rubocop:disable Rails/SkipsModelValidations
    safety_assured do
      change_column_default :user_settings, :create_pr_idle_timeout_seconds, 360
      change_column_null :user_settings, :create_pr_idle_timeout_seconds, false
    end
  end
end
