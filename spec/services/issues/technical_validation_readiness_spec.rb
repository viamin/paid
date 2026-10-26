# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::TechnicalValidationReadiness do # @spec PARTIAL-CLOSEOUT-030
  context "when inspecting execution readiness" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account:) }

    it "uses a registered compatible backend rather than local workspace availability" do
      host = create(:docker_host, account:)

      result = described_class.call(project:)

      expect(result).to be_ready
      expect(result.evidence.fetch("candidate_hosts")).to contain_exactly(host.identifier)
    end

    it "names the setup action when no compatible backend is registered" do
      result = described_class.call(project:)

      expect(result.code).to eq(:no_compatible_backend)
      expect(result.message).to include("Configure or approve a restricted execution host")
    end

    it "does not bypass a disabled tool-sidecar rollout" do
      result = described_class.call(project:, tool_entry_id: "123")

      expect(result.code).to eq(:tool_sidecars_disabled)
      expect(result.message).to include("authorized rollout owner")
    end
  end

  context "when requesting validation" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account:) }
    let(:project) { create(:project, account:, created_by: user) }
    let(:issue) { create(:issue, project:, github_state: "open", paid_state: "in_progress") }

    before do
      create(:docker_host, account:)
      create(:issue, :pull_request, project:, github_state: "closed", pr_review_phase: "merged", parent_issue_id: issue.id)
    end

    it "queues an isolated continuation with the durable validation contract" do
      result = Issues::RequestTechnicalValidation.call(issue:, actor: user)

      expect(result).to be_success
      expect(result.agent_run.custom_prompt).to include("Do not run code on the control plane")
      expect(result.agent_run.reconciliation.fetch("technical_validation")).to include("status" => "queued")
    end
  end
end
