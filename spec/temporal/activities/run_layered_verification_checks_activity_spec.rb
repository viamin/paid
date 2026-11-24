# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::RunLayeredVerificationChecksActivity do
  let(:response_class) do
    Class.new(Struct.new(:output)) do
      def success? = true
    end
  end
  let(:dependencies) do
    { "environment" => { "immutable" => true, "digest" => "sha256:runtime" },
      "producer_versions" => { "paid" => "1.2.3" },
      "tool_versions" => { "tlc_runtime_image_digest" => "sha256:runtime" } }
  end

  def stub_discovery(audit:, scope_output: "", semantic_unmapped: [], scope_directories: [ "docs/intent/payments" ])
    allow(audit).to receive(:execute_in_execution_environment).with(
      [ "git", "ls-files", "--", *scope_directories ], timeout: 60, stream: false
    ).and_return(Containers::Provision::Result.success(stdout: scope_output, stderr: "", exit_code: 0))
    allow(audit).to receive(:execute_in_execution_environment).with(
      [ "head", "-c", anything, "--", anything ], timeout: 60, stream: false
    ).and_return(Containers::Provision::Result.success(stdout: "", stderr: "", exit_code: 0))
    allow(Llm::Request).to receive(:call).and_return(response_class.new({ "unmapped" => semantic_unmapped }.to_json))
  end

  def formal_audit(obligation, extra_metadata = {})
    audit = create(:agent_run, goal: "layered_verification_audit", status: "running", project: obligation.project)
    audit.update!(external_metadata: { "layered_verification" => {
      "obligation_ids" => [ obligation.id ], "target_revision" => "code123",
      "plan" => { obligation.id.to_s => { "selected_checks" => [ "formal_verification" ],
        "required_inputs" => [ "model/Checkout.tla", "model/Checkout.cfg" ] } }
    }.merge(extra_metadata) })
    audit
  end

  def stub_tlc_violation(audit)
    command_result = Containers::Provision::Result.success(stdout: "Error: Invariant Safety is violated.\n", stderr: "", exit_code: 12)
    allow(audit).to receive(:execute_in_execution_environment).with(
      [ "tlc", "-metadir", a_string_matching(%r{\A/tmp/paid-layered-verification-tlc-[0-9a-f]{24}\z}), "-config", "model/Checkout.cfg", "model/Checkout.tla" ], timeout: 60, stream: false
    ).and_return(command_result)
  end

  def expect_counterexample_upload(audit, obligation)
    expected_key = "layered-verification/#{audit.project.account_id}/#{audit.project_id}/#{audit.id}/#{obligation.id}/tlc-output.txt"
    artifact_storage = instance_double(ArtifactStorage)
    allow(ArtifactStorage).to receive(:new).and_return(artifact_storage)
    expect(artifact_storage).to receive(:upload_io) do |io:, key:, content_type:|
      expect(io.read).to eq("Error: Invariant Safety is violated.\n\n")
      expect(key).to eq(expected_key)
      expect(content_type).to eq("text/plain")
    end
    expected_key
  end

  # @spec LAYERED-VERIFY-008 LAYERED-VERIFY-022 LAYERED-VERIFY-024
  it "runs a selected TLC check in the audit container and persists its parsed result" do
    obligation = create(:layered_verification_obligation, external_revision: "intent123")
    audit = formal_audit(obligation)
    stub_discovery(audit:, scope_output: "docs/intent/payments/payment-specs.md\n")
    stub_tlc_violation(audit)
    allow(AgentRun).to receive(:find).with(audit.id).and_return(audit)
    evidence_key = expect_counterexample_upload(audit, obligation)

    described_class.new.execute(agent_run_id: audit.id)

    expect(obligation.check_results.where(producer: "formal_verification").sole).to have_attributes(
      agent_run: audit, execution_state: "completed",
      obligation_coverage: "contradicted", cause_signature: "tlc-invariant-violation",
      evidence_ref: evidence_key
    )
    expect(obligation.check_results.where(producer: "formal_verification").sole.input_revision).to include("code" => "code123", "external_revision" => "intent123")
  end

  it "bounds the inline TLC evidence summary" do
    obligation = create(:layered_verification_obligation)
    audit = formal_audit(obligation)
    command_result = Containers::Provision::Result.success(
      stdout: "Model checking completed.\n#{"detail" * 1_000}", stderr: "", exit_code: 0
    )
    allow(audit).to receive(:execute_in_execution_environment).and_return(command_result)
    stub_discovery(audit:)
    allow(AgentRun).to receive(:find).with(audit.id).and_return(audit)

    described_class.new.execute(agent_run_id: audit.id)

    expect(obligation.check_results.where(producer: "formal_verification").sole.evidence_summary.fetch("output").length).to be <= 2_000
  end

  it "records a selected formal check without a declared pair as non-applicable" do
    obligation = create(:layered_verification_obligation)
    audit = create(:agent_run, goal: "layered_verification_audit", status: "running", project: obligation.project)
    audit.update!(external_metadata: {
      "layered_verification" => {
        "obligation_ids" => [ obligation.id ], "target_revision" => "code123",
        "plan" => { obligation.id.to_s => { "selected_checks" => [ "formal_verification" ] } }
      }
    })

    described_class.new.execute(agent_run_id: audit.id)

    expect(obligation.check_results.where(producer: "formal_verification").sole).to have_attributes(
      execution_state: "non_applicable", obligation_coverage: "unresolved",
      limitations: "no declared TLA+ model/config pair"
    )
  end

  # @spec LAYERED-VERIFY-009
  it "records unmapped scope material as a linkage-freshness result" do
    obligation = create(:layered_verification_obligation, external_revision: "intent123")
    obligation.correspondence_claims.create!(
      claim_type: "business_to_model", source_reference: "docs/intent/payments/payment-specs.md#L3",
      target_reference: "app/models/payment.rb", abstraction_boundaries: "Text maps to API surface.",
      assumptions: "Single-currency checkout."
    )
    audit = create(:agent_run, goal: "layered_verification_audit", status: "running", project: obligation.project)
    audit.update!(external_metadata: { "layered_verification" => { "obligation_ids" => [ obligation.id ],
      "target_revision" => "code123" } })
    stub_discovery(audit:, scope_output: "docs/intent/payments/payment-specs.md\ndocs/intent/payments/unmapped-spec.md\n",
      semantic_unmapped: [ "docs/intent/payments/payment-specs.md#refund-clause" ],
      scope_directories: [ "app/models", "docs/intent/payments" ])
    allow(AgentRun).to receive(:find).with(audit.id).and_return(audit)

    described_class.new.execute(agent_run_id: audit.id)

    linkage = obligation.check_results.find_by!(producer: "linkage_freshness")
    expect(linkage).to have_attributes(agent_run: audit, execution_state: "incomplete", obligation_coverage: "unresolved")
    expect(linkage.recorder_verified).to eq("structural_unmapped_material" => [ "docs/intent/payments/unmapped-spec.md" ])
    expect(linkage.agent_reported).to eq("semantic_unmapped_material" => [ "docs/intent/payments/payment-specs.md#refund-clause" ])
    expect(linkage.limitations).to include("bounded semantic read-through")
  end

  # @spec LAYERED-VERIFY-009
  it "does not append duplicate linkage-freshness results when the activity retries" do
    obligation = create(:layered_verification_obligation, external_revision: "intent123")
    audit = create(:agent_run, goal: "layered_verification_audit", status: "running", project: obligation.project)
    audit.update!(external_metadata: { "layered_verification" => { "obligation_ids" => [ obligation.id ],
      "target_revision" => "code123" } })
    stub_discovery(audit:, scope_output: "docs/intent/payments/unmapped-spec.md\n")
    allow(AgentRun).to receive(:find).with(audit.id).and_return(audit)

    2.times { described_class.new.execute(agent_run_id: audit.id) }

    expect(obligation.check_results.where(agent_run: audit, producer: "linkage_freshness").count).to eq(1)
  end

  it "discloses that linkage freshness could not be established when structural discovery fails" do
    obligation = create(:layered_verification_obligation)
    audit = create(:agent_run, goal: "layered_verification_audit", status: "running", project: obligation.project)
    audit.update!(external_metadata: { "layered_verification" => {
      "obligation_ids" => [ obligation.id ], "target_revision" => "code123"
    } })
    allow(audit).to receive(:execute_in_execution_environment).and_raise(Containers::Provision::ProvisionError, "Container not provisioned")
    allow(AgentRun).to receive(:find).with(audit.id).and_return(audit)

    described_class.new.execute(agent_run_id: audit.id)

    linkage = obligation.check_results.find_by!(producer: "linkage_freshness")
    expect(linkage.evidence_summary.fetch("unmapped_material")).to be_empty
    expect(linkage.limitations).to include("Structural discovery could not execute")
  end

  # @spec LAYERED-VERIFY-019
  it "reuses a prior result the admission impact marked reusable instead of rerunning TLC" do
    obligation = create(:layered_verification_obligation, external_revision: "intent123")
    prior_run = create(:agent_run, goal: "layered_verification_audit", status: "completed", project: obligation.project)
    prior = create(:layered_verification_check_result, obligation:, agent_run: prior_run,
      execution_state: "completed", obligation_coverage: "supported", limitations: "bounded state space",
      input_revision: { "code" => "code123", "external_revision" => "intent123", "dependencies" => dependencies })
    audit = formal_audit(obligation,
      "dependencies" => dependencies,
      "input_revisions" => { obligation.id.to_s => "intent123" },
      "impact" => { "reused_check_result_ids" => [ prior.id ] })
    stub_discovery(audit:)
    allow(AgentRun).to receive(:find).with(audit.id).and_return(audit)

    result = described_class.new.execute(agent_run_id: audit.id)

    expect(result).to eq(agent_run_id: audit.id, check_result_count: 1)
    expect(audit).not_to have_received(:execute_in_execution_environment).with(
      [ "tlc", anything, anything, anything, anything ], timeout: 60, stream: false
    )
    carried = obligation.check_results.where(agent_run: audit, producer: "formal_verification").sole
    expect(carried).to have_attributes(execution_state: "completed", obligation_coverage: "supported")
    expect(carried.recorder_verified).to eq("reused_result_id" => prior.id)
  end

  # @spec LAYERED-VERIFY-019
  it "does not rerun a formal check already recorded before an activity retry" do
    obligation = create(:layered_verification_obligation, external_revision: "intent123")
    audit = formal_audit(obligation)
    stub_discovery(audit:)
    stub_tlc_violation(audit)
    allow(AgentRun).to receive(:find).with(audit.id).and_return(audit)
    expect_counterexample_upload(audit, obligation)

    2.times { described_class.new.execute(agent_run_id: audit.id) }

    expect(obligation.check_results.where(agent_run: audit, producer: "formal_verification").count).to eq(1)
  end
end
