# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe ShadowEvaluationExecutionJob do
  let(:project) { create(:project) }
  let(:evaluation) { create(:intent_conformance_shadow_evaluation, project: project) }

  it "does not execute a cancelled evaluation" do
    evaluation.update!(status: "cancelled", labels_frozen_at: Time.current)

    expect(IntentConformance::ShadowEvaluation::ExecuteReviewer).not_to receive(:call)

    described_class.perform_now(project.id, evaluation.id)
  end

  it "runs the shared reviewer service for a queued evaluation" do
    evaluation.update!(status: "queued", labels_frozen_at: Time.current)
    result = instance_double(IntentConformance::ShadowEvaluation::ExecuteReviewer::Result, success?: true)
    allow(IntentConformance::ShadowEvaluation::ExecuteReviewer).to receive(:call).and_return(result)
    allow(IntentConformance::ShadowEvaluation::CompileReport).to receive(:call)

    described_class.perform_now(project.id, evaluation.id)

    expect(IntentConformance::ShadowEvaluation::ExecuteReviewer).to have_received(:call).with(evaluation: evaluation)
  end

  it "compiles a missing report when execution completed before a retry" do
    evaluation.update!(status: "completed", labels_frozen_at: Time.current)
    create(:intent_conformance_shadow_evaluation_run, shadow_evaluation: evaluation)
    allow(IntentConformance::ShadowEvaluation::CompileReport).to receive(:call)

    expect(IntentConformance::ShadowEvaluation::ExecuteReviewer).not_to receive(:call)

    described_class.perform_now(project.id, evaluation.id)

    expect(IntentConformance::ShadowEvaluation::CompileReport).to have_received(:call).with(evaluation: evaluation)
  end

  it "makes an exhausted report compilation failure retryable without discarding runs" do
    evaluation.update!(status: "completed", labels_frozen_at: Time.current)
    run = create(:intent_conformance_shadow_evaluation_run, shadow_evaluation: evaluation)
    allow(IntentConformance::ShadowEvaluation::CompileReport).to receive(:call)
      .and_raise(StandardError, "report storage unavailable")
    job = described_class.new(project.id, evaluation.id)
    job.exception_executions = { "[StandardError]" => 2 }

    expect { job.perform_now }.to raise_error(StandardError, "report storage unavailable")

    expect(evaluation.reload).to have_attributes(status: "failed", last_failure_reason: "report storage unavailable")
    expect(evaluation.runs).to contain_exactly(run)
    expect(evaluation.queue_execution!).to be(true)
  end

  it "converges an unsuccessful service result to a retryable terminal state" do
    evaluation.update!(status: "queued", labels_frozen_at: Time.current)
    create(:intent_conformance_shadow_evaluation_run, shadow_evaluation: evaluation)
    result = IntentConformance::ShadowEvaluation::ExecuteReviewer::Result.new(
      success: false,
      error: "corpus manifest changed",
      evaluation: nil,
      executed: 0,
      failed: 0
    )
    allow(IntentConformance::ShadowEvaluation::ExecuteReviewer).to receive(:call).and_return(result)
    allow(IntentConformance::ShadowEvaluation::CompileReport).to receive(:call)

    described_class.perform_now(project.id, evaluation.id)

    expect(evaluation.reload).to have_attributes(status: "partial", last_failure_reason: "corpus manifest changed")
    expect(IntentConformance::ShadowEvaluation::CompileReport).to have_received(:call).with(evaluation: evaluation)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-011
  it "preserves a cancellation requested while a failed worker is recovering" do
    evaluation.update!(status: "running", labels_frozen_at: Time.current, execute_started_at: Time.current)
    result = IntentConformance::ShadowEvaluation::ExecuteReviewer::Result.new(
      success: false,
      error: "provider unavailable",
      evaluation: nil,
      executed: 0,
      failed: 0
    )
    allow(IntentConformance::ShadowEvaluation::ExecuteReviewer).to receive(:call) do
      evaluation.request_cancellation!(actor: evaluation.created_by)
      result
    end
    allow(IntentConformance::ShadowEvaluation::CompileReport).to receive(:call)

    described_class.perform_now(project.id, evaluation.id)

    expect(evaluation.reload).to be_cancelled
  end

  it "reports an incident after retries are exhausted" do
    notifier = instance_double(Paid::ExceptionNotifier, call: nil)
    allow(Paid::ExceptionNotifier).to receive(:new).and_return(notifier)
    allow(IntentConformance::ShadowEvaluation::ExecuteReviewer).to receive(:call)
      .and_raise(StandardError, "provider unavailable")
    allow(IntentConformance::ShadowEvaluation::CompileReport).to receive(:call)
    job = described_class.new(project.id, evaluation.id)
    job.exception_executions = { "[StandardError]" => 2 }

    expect { job.perform_now }.to raise_error(StandardError, "provider unavailable")

    expect(evaluation.reload).to be_failed
    expect(notifier).to have_received(:call).with(
      an_instance_of(StandardError),
      data: hash_including(project_id: project.id)
    )
  end

  it "uses the dedicated shadow evaluation queue" do
    expect(described_class.queue_name).to eq("shadow_evaluation")
  end
end
