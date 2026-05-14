# frozen_string_literal: true

class IncreaseCreatePrIdleTimeoutDefault < ActiveRecord::Migration[8.1]
  def change
    change_column_default :user_settings, :create_pr_idle_timeout_seconds, from: 300, to: 360

    reversible do |dir|
      dir.up do
        UserSetting.where(create_pr_idle_timeout_seconds: 300).update_all(create_pr_idle_timeout_seconds: 360)
      end
    end
  end
end
