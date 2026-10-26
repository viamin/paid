# frozen_string_literal: true

class AddOriginatingIssueToShadowEvaluations < ActiveRecord::Migration[8.1]
  def change
    add_reference :intent_conformance_shadow_evaluations, :originating_issue,
      foreign_key: { to_table: :issues }, null: true,
      comment: "Partial-closeout issue from which this evaluation was started."
  end
end
