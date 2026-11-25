# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261124133739_enable_tenant_rls_on_shared_delivery_evidence_associations")
require Rails.root.join("db/migrate/20261125140307_nullify_historical_actor_references_on_user_deletion")

RSpec.describe NullifyHistoricalActorReferencesOnUserDeletion do
  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }

  # @spec ACCOUNT-ADMIN-005
  it "restores validated historical actor foreign keys on rollback" do
    connection.transaction(requires_new: true) do
      expect { migration.migrate(:down) }.not_to raise_error

      expect(actor_foreign_key(:issue_continuation_requests, :requested_by_id)).to be_validated
      expect(actor_foreign_key(:shared_delivery_evidence_associations, :authorized_by_id)).to be_validated

      raise ActiveRecord::Rollback
    end
  end

  private

  def actor_foreign_key(table, column)
    connection.foreign_keys(table).find { |key| key.options[:column].to_s == column.to_s }
  end
end
