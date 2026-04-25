# frozen_string_literal: true

class CreateNotificationRuleStates < ActiveRecord::Migration[8.1]
  def change
    create_table :notification_rule_states do |t|
      t.references :account, null: false, foreign_key: true
      t.string :source, null: false
      t.references :subject, polymorphic: true, null: false
      t.jsonb :metadata, null: false, default: {}
      t.datetime :first_seen_at
      t.datetime :last_seen_at

      t.timestamps
    end

    add_index :notification_rule_states,
      [ :account_id, :source, :subject_type, :subject_id ],
      unique: true,
      name: "index_notification_rule_states_on_dedup"
  end
end
