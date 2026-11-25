# frozen_string_literal: true

class ValidateHistoricalActorReferencesOnUserDeletion < ActiveRecord::Migration[8.1]
  def up
    validate_foreign_key :issue_continuation_requests, :users, column: :requested_by_id
    validate_foreign_key :shared_delivery_evidence_associations, :users, column: :authorized_by_id
  end

  def down
  end
end
