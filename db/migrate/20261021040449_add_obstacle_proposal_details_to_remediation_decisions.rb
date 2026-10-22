# frozen_string_literal: true

class AddObstacleProposalDetailsToRemediationDecisions < ActiveRecord::Migration[8.1]
  def change
    add_column :remediation_decisions, :obstacle_kind, :string, null: false, default: "unknown",
      comment: "Semantic classification: infrastructure_configuration, implementation, or unknown."
    add_column :remediation_decisions, :proposal_context, :jsonb, null: false, default: {},
      comment: "Bounded affected scope, evidence snapshot, validation plan, and uncertainty."
    add_column :remediation_decisions, :dismissal_reason, :text,
      comment: "Operator rationale retained when a recurring proposal is dismissed."
    add_column :remediation_decisions, :dismissed_at, :datetime,
      comment: "When the operator dismissed this proposal."
    add_column :remediation_decisions, :pre_remediation_exposure_count, :integer,
      comment: "Comparable run exposure in the detector window before a correction."
    add_column :remediation_decisions, :post_remediation_exposure_count, :integer,
      comment: "Comparable run exposure after an accepted correction."
  end
end
