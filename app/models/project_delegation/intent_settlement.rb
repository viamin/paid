# frozen_string_literal: true

module ProjectDelegation
  # @spec PROJECT-DELEGATION-002
  class IntentSettlement < ApplicationRecord
    self.table_name = "project_delegation_intent_settlements"
    DISPOSITIONS = %w[settled rejected amended].freeze

    belongs_to :intent_checkpoint, class_name: "ProjectDelegation::IntentCheckpoint"
    belongs_to :settled_by, class_name: "User"

    validates :disposition, inclusion: { in: DISPOSITIONS }
    validates :design_revision, :acceptance_revision, :settled_at, presence: true

    before_update { raise ActiveRecord::ReadOnlyRecord, "intent settlements are immutable" }
    before_destroy { raise ActiveRecord::ReadOnlyRecord, "intent settlements are immutable" }
  end
end
