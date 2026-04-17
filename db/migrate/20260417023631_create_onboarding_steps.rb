# frozen_string_literal: true

class CreateOnboardingSteps < ActiveRecord::Migration[8.1]
  def change
    create_table :onboarding_steps do |t|
      t.references :account, null: false, foreign_key: true
      t.string :step, null: false
      t.integer :position, null: false
      t.string :status, default: "pending", null: false
      t.datetime :completed_at
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :onboarding_steps, [ :account_id, :step ], unique: true
    add_index :onboarding_steps, [ :account_id, :position ]
  end
end
