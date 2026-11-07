# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-007
RSpec.describe ProjectDelegation::ExpansionPause do
  it "has a valid factory" do
    expect(build(:project_delegation_expansion_pause)).to be_valid
  end

  it "rejects an unknown pause reason" do
    pause = build(:project_delegation_expansion_pause, reason: "whim")

    expect(pause).not_to be_valid
    expect(pause.errors[:reason]).to be_present
  end

  it "allows each RDR-080 pause reason" do
    %w[material_reversal security_breach tenant_breach trust_breach missing_evidence].each do |reason|
      pause = build(:project_delegation_expansion_pause, reason:)

      expect(pause).to be_valid, "expected #{reason} to be valid"
    end
  end

  it "requires the resolving actor and timestamp together" do
    pause = build(:project_delegation_expansion_pause, resolved_at: Time.current)

    expect(pause).not_to be_valid
    expect(pause.errors[:resolved_by]).to be_present
  end

  describe ".unresolved_for" do
    it "matches only unresolved pauses for the project" do
      project = create(:project)
      other_project = create(:project, account: project.account)
      unresolved = create(:project_delegation_expansion_pause, project:)
      create(:project_delegation_expansion_pause, project: other_project)
      resolved = create(:project_delegation_expansion_pause, project:,
        resolved_at: Time.current, resolved_by: create(:user, :member, account: project.account))

      expect(described_class.unresolved_for(project)).to contain_exactly(unresolved)
      expect(resolved).to be_persisted
    end
  end
end
