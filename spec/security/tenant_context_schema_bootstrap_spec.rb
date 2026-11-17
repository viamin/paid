# frozen_string_literal: true

require "rails_helper"

# No policy-installation fixture: this exercises the schema Rails loaded.
# @spec POSTGRESQL-PERSISTENCE-001 POSTGRESQL-PERSISTENCE-002 POSTGRESQL-PERSISTENCE-012
RSpec.describe TenantContext, :tenant_isolation do
  def projection_records
    described_class.with_system_access do
      projects = [ create(:project), create(:project) ]
      checkpoints = projects.map { |project| PartialCloseoutProjection.create!(project:, computed_at: Time.current, generation: SecureRandom.uuid) }
      entries = checkpoints.map do |checkpoint|
        PartialCloseoutProjectionEntry.create!(project: checkpoint.project, issue: create(:issue, project: checkpoint.project),
          evidence_digest: "a" * 64, projection_generation: checkpoint.generation)
      end
      [ projects, checkpoints, entries ]
    end
  end

  it "uses a runtime role that cannot bypass row-level security" do
    role = ActiveRecord::Base.connection.select_one("SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user")
    expect(role).to eq("rolsuper" => false, "rolbypassrls" => false)
  end

  it "isolates later layered-verification findings without installing policies in the test" do
    projects, findings = described_class.with_system_access do
      projects = [ create(:project), create(:project) ]
      findings = projects.map do |project|
        create(:layered_verification_finding, project:, obligation: create(:layered_verification_obligation, project:),
          agent_run: create(:agent_run, project:))
      end
      [ projects, findings ]
    end
    described_class.with(projects.first.account) do
      expect(LayeredVerificationFinding.where(id: findings.map(&:id))).to contain_exactly(findings.first)
    end
    described_class.with(nil) do
      expect(LayeredVerificationFinding.where(id: findings.map(&:id))).to be_empty
    end
  end

  it "isolates projection rows and rejects foreign checkpoints after unmodified bootstrap" do
    projects, checkpoints, entries = projection_records
    described_class.with(projects.first.account) do
      expect(PartialCloseoutProjection.where(id: checkpoints.map(&:id))).to contain_exactly(checkpoints.first)
      expect(PartialCloseoutProjectionEntry.where(id: entries.map(&:id))).to contain_exactly(entries.first)
    end
    described_class.with(nil) do
      expect(PartialCloseoutProjection.where(id: checkpoints.map(&:id))).to be_empty
      expect(PartialCloseoutProjectionEntry.where(id: entries.map(&:id))).to be_empty
    end
    foreign = described_class.with_system_access { create(:project, account: projects.last.account) }
    described_class.with(projects.first.account) do
      expect do
        PartialCloseoutProjection.transaction(requires_new: true) { PartialCloseoutProjection.create!(project: foreign) }
      end.to raise_error(ActiveRecord::StatementInvalid, /row-level security/)
    end
  end
end
