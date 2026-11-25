# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261125140307_nullify_historical_actor_references_on_user_deletion")

RSpec.describe NullifyHistoricalActorReferencesOnUserDeletion do # @spec PARTIAL-CLOSEOUT-064
  it "refuses an unsafe rollback before changing historical foreign keys" do
    before = historical_foreign_keys

    expect { described_class.new.migrate(:down) }.to raise_error(
      ActiveRecord::IrreversibleMigration, /historical attribution cannot be reconstructed/
    )
    expect(historical_foreign_keys).to eq(before)
  end

  def historical_foreign_keys
    ActiveRecord::Base.connection.select_rows(<<~SQL)
      SELECT conname, pg_get_constraintdef(oid), convalidated
      FROM pg_constraint
      WHERE contype = 'f' AND conrelid IN (
        'issue_continuation_requests'::regclass, 'shared_delivery_evidence_associations'::regclass
      )
      ORDER BY conname
    SQL
  end
end
