# frozen_string_literal: true

class AddExecutionLifecycleToIntentConformanceShadowEvaluations < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :intent_conformance_shadow_evaluations, :cancellation_requested_at, :datetime,
      comment: "Operator request to stop after the current case; collected evidence remains intact.", if_not_exists: true
    add_column :intent_conformance_shadow_evaluations, :cancelled_at, :datetime,
      comment: "When a queued or running reviewer execution cooperatively stopped.", if_not_exists: true
    add_column :intent_conformance_shadow_evaluations, :execution_heartbeat_at, :datetime,
      comment: "Last durable execution progress signal, used to recover an interrupted worker.", if_not_exists: true
    add_column :intent_conformance_shadow_evaluations, :execution_attempts, :integer, null: false, default: 0,
      comment: "Number of worker attempts for the current evidence generation.", if_not_exists: true

    add_index :intent_conformance_shadow_evaluations, %i[status execution_heartbeat_at],
      name: "idx_shadow_evaluations_execution_recovery", algorithm: :concurrently, if_not_exists: true

    reversible do |direction|
      direction.up do
        safety_assured do
          execute <<~SQL.squish
            UPDATE intent_conformance_shadow_evaluations
            SET status = 'running'
            WHERE status = 'executing'
          SQL
        end
      end
    end
  end
end
