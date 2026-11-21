# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::AssessSourceClosureActivity do
  let(:project) { create(:project) }
  let(:run) { create(:agent_run, project:, issue: create(:issue, project:)) }

  # @spec PARTIAL-CLOSEOUT-058 PARTIAL-CLOSEOUT-044
  it "retains bounded rejection diagnostics while preserving the Temporal failure contract" do
    failure = oversized_assessment_failure
    allow(Llm::AnalyzePartialCloseout).to receive(:call) do
      concurrent = AgentRun.find(run.id)
      concurrent.update!(reconciliation: concurrent.reconciliation.merge("operator_note" => "retained"))
      raise failure
    end

    expect { described_class.new.execute(agent_run_id: run.id) }
      .to raise_error(Temporalio::Error::ApplicationError) do |error|
        expect(error.details).to eq([ { "category" => "invalid_assessment" } ])
        expect(error).not_to be_retryable
      end

    diagnostic = run.reload.reconciliation.fetch("assessment_failure")
    expect(diagnostic).to include("category" => "invalid_assessment", "provider" => "opencode",
      "model" => "glm-5.3", "request_id" => "r" * 120,
      "invalid_fields" => Array.new(10) { { "path" => "p" * 120, "expected" => "object", "actual" => "string" } })
    expect(diagnostic.fetch("at")).to be_present
    expect(run.reconciliation.to_json).not_to include("raw-private-payload")
    expect(run.reconciliation).not_to have_key("assessment")
    expect(run.reconciliation.fetch("operator_note")).to eq("retained")
    expect(run.issue.reload.github_state).to eq("open")
  end

  # @spec PARTIAL-CLOSEOUT-058 PARTIAL-CLOSEOUT-044
  it "retains the known configuration category without inventing provider output" do
    allow(Llm::AnalyzePartialCloseout).to receive(:call).and_raise(AgentHarness::ConfigurationError, "missing setup")

    expect { described_class.new.execute(agent_run_id: run.id) }
      .to raise_error(Temporalio::Error::ApplicationError) do |error|
        expect(error.details).to eq([ { "category" => "configuration_unavailable" } ])
        expect(error).not_to be_retryable
      end

    diagnostic = run.reload.reconciliation.fetch("assessment_failure")
    expect(diagnostic).to include("category" => "configuration_unavailable", "at" => be_present)
    expect(diagnostic).not_to have_key("provider")
    expect(run.reconciliation).not_to have_key("assessment")
  end

  def oversized_assessment_failure
    fields = Array.new(12) { { path: "p" * 200, expected: "object", actual: "string", response: "raw-private-payload" } }
    Llm::AnalyzePartialCloseout::AssessmentFailure.new("assessment rejected",
      category: "invalid_assessment", provider: "opencode", model: "glm-5.3", request_id: "r" * 200,
      invalid_fields: fields, provider_response: "raw-private-payload")
  end

  # @spec LLM-ROUTING-008
  it "tries the owner's enabled fallback before parking a pushed run" do
    owner = project.effective_owner
    primary = create(:runner, user: owner, runner_key: "codex")
    fallback = create(:runner, user: owner, runner_key: "gemini")
    run.update!(runner: primary)
    owner.settings.update!(fallback_enabled: true, issue_analysis_fallback_runners: [ "gemini" ])
    failure = Llm::AnalyzePartialCloseout::AssessmentFailure.new("assessment failed", category: "unsuccessful_response")
    allow(Llm::AnalyzePartialCloseout).to receive(:call).and_raise(failure)

    expect { described_class.new.execute(agent_run_id: run.id) }
      .to raise_error(Temporalio::Error::ApplicationError)
    expect(Llm::AnalyzePartialCloseout).to have_received(:call).with(
      agent_run: run, fallback_runner_identifiers: array_including(fallback.routing_key),
      timeout: be_between(60, 110)
    )
  end

  # @spec LLM-ROUTING-008 RUNNER-USAGE-001 RUNNER-USAGE-002
  it "does not use an issue-analysis fallback that is opted out of fallback usage" do
    owner = project.effective_owner
    primary = create(:runner, user: owner, runner_key: "codex")
    opted_out = create(:runner, user: owner, runner_key: "gemini", enabled_for_fallback: false)
    run.update!(runner: primary)
    owner.settings.update!(fallback_enabled: true, issue_analysis_fallback_runners: [ "gemini" ])
    failure = Llm::AnalyzePartialCloseout::AssessmentFailure.new("assessment failed", category: "unsuccessful_response")
    allow(Llm::AnalyzePartialCloseout).to receive(:call).and_raise(failure)

    expect { described_class.new.execute(agent_run_id: run.id) }
      .to raise_error(Temporalio::Error::ApplicationError)
    expect(Llm::AnalyzePartialCloseout).to have_received(:call).with(
      agent_run: run, fallback_runner_identifiers: array_excluding("gemini", opted_out.routing_key),
      timeout: be_between(60, 110)
    )
  end

  # @spec LLM-ROUTING-008
  it "does not use configured alternatives when fallback is disabled" do
    owner = project.effective_owner
    owner.settings.update!(fallback_enabled: false, issue_analysis_fallback_runners: [ "opencode" ])
    failure = Llm::AnalyzePartialCloseout::AssessmentFailure.new("assessment failed", category: "unsuccessful_response")
    allow(Llm::AnalyzePartialCloseout).to receive(:call).and_raise(failure)

    expect { described_class.new.execute(agent_run_id: run.id) }
      .to raise_error(Temporalio::Error::ApplicationError)
    expect(Llm::AnalyzePartialCloseout).to have_received(:call).with(
      agent_run: run, fallback_runner_identifiers: [], timeout: Llm::AnalyzePartialCloseout::TIMEOUT
    )
  end

  # @spec PARTIAL-CLOSEOUT-044
  it "exports transport assessment failures as retryable Temporal failures" do
    %w[timeout transport_error unsuccessful_response].each do |category|
      failure = Llm::AnalyzePartialCloseout::AssessmentFailure.new("assessment failed", category:)
      allow(Llm::AnalyzePartialCloseout).to receive(:call).and_raise(failure)

      expect { described_class.new.execute(agent_run_id: run.id) }
        .to raise_error(Temporalio::Error::ApplicationError) do |error|
          expect(error).to be_retryable
          expect(error.details).to eq([ { "category" => category } ])
        end
    end
  end

  # @spec PARTIAL-CLOSEOUT-044
  it "fails closed for authentication and invalid-response categories" do
    %w[authentication_unavailable invalid_json invalid_assessment].each do |category|
      failure = Llm::AnalyzePartialCloseout::AssessmentFailure.new("assessment failed", category:)
      allow(Llm::AnalyzePartialCloseout).to receive(:call).and_raise(failure)

      expect { described_class.new.execute(agent_run_id: run.id) }
        .to raise_error(Temporalio::Error::ApplicationError) { |error| expect(error).not_to be_retryable }
    end
  end
end
