# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Inbox::DecideLayeredVerificationFinding do
  # @spec LAYERED-VERIFY-023
  it "binds the recorded Inbox decision into a fresh review package revision" do
    audit, finding, first = captured_audit_with_finding

    described_class.call(finding:, user: audit.project.created_by, action: "defer",
      reason: "Awaiting the business owner.", external_revision: "abc123")

    successor = audit.review_packages.order(:revision_number).last
    expect(successor.id).not_to eq(first.id)
    expect(successor.revision_number).to eq(2)
    expect(successor.bound_inputs["inbox_decisions"]).to contain_exactly(
      include("finding_id" => finding.id, "selected_action" => "defer")
    )
    expect(audit.review_packages.find(first.id).bound_inputs["inbox_decisions"]).to be_empty
  end

  private

  def captured_audit_with_finding
    account = create(:account)
    user = create(:user, :owner, account:)
    project = create(:project, account:, created_by: user)
    source = "PAYMENTS-017 requires one captured charge."
    obligation = create(:layered_verification_obligation, project:,
      canonical_source_path: "docs/intent/payments-specs.md",
      external_revision: Digest::SHA256.hexdigest(source))
    github_client = instance_double(GithubClient)
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:ref).with(project.full_name, "heads/#{project.default_branch}")
      .and_return(OpenStruct.new(object: OpenStruct.new(sha: "abc123")))
    allow(github_client).to receive(:file_content)
      .with(project.full_name, path: "docs/intent/payments-specs.md", ref: "abc123").and_return(source)
    audit = create(:agent_run, project:, goal: "layered_verification_audit", status: "completed")
    audit.update!(external_metadata: {
      "layered_verification" => { "obligation_ids" => [ obligation.id ], "target_revision" => "abc123",
                                  "plan" => { obligation.id.to_s => { "selected_checks" => [ "semantic_audit" ] } } }
    })
    create(:layered_verification_check_result, obligation:, agent_run: audit,
      input_revision: { "external_revision" => obligation.external_revision, "target_revision" => "abc123" })
    first = LayeredVerification::ReviewPackages::Capture.call(agent_run: audit)
    finding = create(:layered_verification_finding, project:, obligation:, agent_run: audit)
    [ audit, finding, first ]
  end
end
