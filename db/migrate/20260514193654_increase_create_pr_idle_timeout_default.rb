# frozen_string_literal: true

class IncreaseCreatePrIdleTimeoutDefault < ActiveRecord::Migration[8.1]
  def up
    change_column_default :user_settings, :create_pr_idle_timeout_seconds, from: 300, to: 360
    UserSetting.where(create_pr_idle_timeout_seconds: 300).update_all(create_pr_idle_timeout_seconds: 360) # rubocop:disable Rails/SkipsModelValidations
  end

  def down
    change_column_default :user_settings, :create_pr_idle_timeout_seconds, from: 360, to: 300
    UserSetting.where(create_pr_idle_timeout_seconds: 360).update_all(create_pr_idle_timeout_seconds: 300) # rubocop:disable Rails/SkipsModelValidations
  end
end
