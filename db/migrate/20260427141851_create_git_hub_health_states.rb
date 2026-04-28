# frozen_string_literal: true

class CreateGitHubHealthStates < ActiveRecord::Migration[8.1]
  def change
    create_table :github_health_states do |t|
      t.string :endpoint, limit: 50, null: false, default: "api"
      t.string :circuit_state, limit: 20, null: false, default: "closed"
      t.integer :failure_count, null: false, default: 0
      t.datetime :circuit_opened_at
      t.text :last_error_message

      t.timestamps
    end

    add_index :github_health_states, :endpoint, unique: true
  end
end
