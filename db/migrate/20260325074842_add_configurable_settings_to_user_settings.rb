# frozen_string_literal: true

class AddConfigurableSettingsToUserSettings < ActiveRecord::Migration[8.1]
  def change
    change_table :user_settings, bulk: true do |t|
      # Token & rate limits
      t.integer :max_tokens_per_run, null: false, default: 10_000_000

      # Goal-specific timeouts
      t.integer :issue_goal_timeout_seconds, null: false, default: 600
      t.integer :issue_goal_idle_timeout_seconds, null: false, default: 120
      t.integer :review_goal_idle_timeout_seconds, null: false, default: 300

      # Git operation timeouts
      t.integer :git_clone_timeout_seconds, null: false, default: 600
      t.integer :git_push_timeout_seconds, null: false, default: 60

      # Prompt building limits
      t.integer :max_prompt_comments, null: false, default: 20
      t.integer :max_comment_length, null: false, default: 2000

      # Style guide byte limits
      t.integer :style_guide_max_raw_bytes, null: false, default: 100_000
      t.integer :style_guide_max_total_bytes, null: false, default: 32_000
      t.integer :style_guide_max_raw_prompt_bytes, null: false, default: 8_000
    end
  end
end
