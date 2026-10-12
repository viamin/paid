# frozen_string_literal: true

class AddReadinessSnapshotToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :readiness_gaps, :jsonb, default: [], null: false,
      comment: "Latest deterministic project-readiness gaps used by the operator Inbox."
    add_column :projects, :readiness_evaluated_at, :datetime,
      comment: "When the current project-readiness snapshot was evaluated against a checkout."
  end
end
