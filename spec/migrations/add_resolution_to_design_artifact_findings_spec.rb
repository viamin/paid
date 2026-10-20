# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261020003850_add_resolution_to_design_artifact_findings")

# @spec OPERATOR-INBOX-018
RSpec.describe AddResolutionToDesignArtifactFindings do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  it "coerces new statuses back to 'open' so the narrower check constraint can be re-applied" do
    ActiveRecord::Migration.suppress_messages { migration.up }
    result = connection.exec_update(<<~SQL.squish)
      INSERT INTO design_artifact_findings (
        project_id, account_id, artifact_path, revision, fingerprint, state, evidence,
        covered_at, status, created_at, updated_at
      )
      SELECT project_id, account_id, artifact_path, revision, 'spec-deferred-marker', state, evidence,
        covered_at, 'deferred', created_at, updated_at
      FROM design_artifact_findings
      LIMIT 1
    SQL

    expect { ActiveRecord::Migration.suppress_messages { migration.down } }.not_to raise_error
    expect(connection.check_constraints(:design_artifact_findings).map(&:name))
      .to include("chk_design_artifact_findings_status")
  ensure
    ActiveRecord::Migration.suppress_messages { migration.up }
  end
end
