# frozen_string_literal: true

require "rails_helper"

# @spec AUTOMATION-PHASES-004 @spec AUTOMATION-PHASES-005 @spec AUTOMATION-PHASES-009
# @spec AUTOMATION-PHASES-012
RSpec.describe Automation::ManualStart::Plan do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:member) { create(:user, :member, account:) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, project:) }

  before do
    FeatureFlags.enable!(:automation_phases, project:)
    project.update!(
      Automation::PhaseSettings::SETTINGS_KEY => {
        Automation::PhaseSettings::PHASES_KEY => { "coding" => false, "merge" => false },
        Automation::PhaseSettings::RELEASE_KEY => false,
        Automation::PhaseSettings::DEPLOYMENT_KEY => false
      }
    )
  end

  def plan(user: owner, phase: "coding", goal: "create_pr", endpoint: nil, continuation: false)
    described_class.new(
      project:, user:, phase:, goal:,
      endpoint:, continuation_selected: continuation
    ).call
  end

  describe "endpoint selection" do
    it "offers every endpoint from the action's phase through merge" do
      expect(plan(phase: "coding").endpoints).to eq(%w[coding merge])
    end

    it "offers the full endpoint menu from a discovery action" do
      expect(plan(phase: "discovery", goal: "create_feature").endpoints)
        .to eq(%w[issue_preparation coding merge])
    end

    it "defaults a discovery action to the first continuation endpoint" do
      expect(plan(phase: "discovery", goal: "create_feature").endpoint).to eq("issue_preparation")
    end

    it "defaults the endpoint to the action's phase when that endpoint exists" do
      expect(plan(phase: "coding").endpoint).to eq("coding")
    end

    it "rejects an endpoint that is not offered for the action" do
      expect { plan(phase: "coding", endpoint: "issue_preparation") }
        .to raise_error(described_class::EndpointNotApplicable)
    end

    it "offers no per-item stop beyond the chosen endpoint" do
      created = plan(phase: "coding", endpoint: "coding", continuation: true)
      grant = created.build_grant(issue:)

      expect(grant.covered_phases).to eq(%w[coding])
    end
  end

  describe "client-refresh payload" do
    it "describes endpoints and per-endpoint notices for goal changes" do
      payload = plan(phase: "discovery", goal: "create_feature").payload

      expect(payload[:default_endpoint]).to eq("issue_preparation")
      expect(payload[:endpoints].map { |endpoint| endpoint[:value] })
        .to eq(%w[issue_preparation coding merge])
      expect(payload[:notices]["merge"]).to include("You selected automation through Merge")
    end
  end

  describe "grant creation" do
    it "creates no grant when continuation was not requested" do
      expect(plan(continuation: false).build_grant(issue:)).to be_nil
      expect(WorkItemContinuationGrant.count).to eq(0)
    end

    it "records the author, scope, endpoint, and source" do
      grant = plan(continuation: true, endpoint: "merge").build_grant(issue:)

      expect(grant).to have_attributes(
        project:, issue:, start_phase: "coding", endpoint: "merge",
        source: "manual_start", created_by: owner
      )
    end

    it "rejects requested continuation without a work item" do
      expect { plan(continuation: true).build_grant(issue: nil) }
        .to raise_error(
          described_class::WorkItemRequired,
          "Select an issue or pull request to authorize automatic continuation."
        )
    end

    it "requires permission to delegate merge" do
      expect { plan(user: member, continuation: true, endpoint: "merge").build_grant(issue:) }
        .to raise_error(described_class::PermissionDenied, /permission to delegate merging/)
    end

    it "permits a non-merge continuation for a user who can start work" do
      expect { plan(user: member, continuation: true, endpoint: "coding").build_grant(issue:) }.not_to raise_error
    end

    # @spec AUTOMATION-PHASES-009
    it "rejects a non-merge continuation from an actor outside the project account" do
      outside_user = create(:user, :owner, account: create(:account))

      expect { plan(user: outside_user, continuation: true, endpoint: "coding").build_grant(issue:) }
        .to raise_error(described_class::PermissionDenied, /permission to delegate this action/)
    end
  end
end
