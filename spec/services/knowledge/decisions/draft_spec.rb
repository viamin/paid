# frozen_string_literal: true

require "rails_helper"

# @spec KNOWLEDGE-010
RSpec.describe Knowledge::Decisions::Draft do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }
  let(:agent_run) do
    create(:agent_run, :completed, project: project, issue: issue,
      base_commit_sha: "aaa0000000000000000000000000000000000000",
      result_commit_sha: "bbb0000000000000000000000000000000000000")
  end

  let(:llm_json) do
    {
      title: "Use JWT for auth",
      summary: "Decided to use JWT.",
      context: "Session auth was insufficient.",
      decision: "Implement JWT auth.",
      consequences: "Clients must refresh tokens.",
      tags: %w[auth api]
    }.to_json
  end

  let(:llm_response) do
    response = Object.new
    json = llm_json
    response.define_singleton_method(:output) { json }
    response.define_singleton_method(:success?) { true }
    response
  end

  before do
    allow(Knowledge::AnalysisRunner).to receive(:available?).and_return(false)
    allow(AgentHarness).to receive(:send_message).and_return(llm_response)
    # Default: preserve CLI transport so existing exact-match expectations
    # pass. Individual specs flip this on to prove text-mode routing.
    allow(Llm::TextMode).to receive(:options).and_return({})
    agent_run.log!("stdout", "Implemented JWT authentication for API endpoints")
  end

  describe ".call" do
    it "creates a persisted active decision record" do
      record = described_class.call(agent_run: agent_run)

      expect(record).to be_a(DecisionRecord)
      expect(record).to be_persisted
      expect(record.status).to eq("active")
    end

    it "populates record fields from LLM response" do
      record = described_class.call(agent_run: agent_run)

      expect(record.title).to eq("Use JWT for auth")
      expect(record.summary).to eq("Decided to use JWT.")
      expect(record.decision).to eq("Implement JWT auth.")
      expect(record.tags).to eq(%w[auth api])
    end

    it "links record to project, agent run, and issue" do
      record = described_class.call(agent_run: agent_run)

      expect(record.project).to eq(project)
      expect(record.agent_run).to eq(agent_run)
      expect(record.issue).to eq(issue)
    end

    it "stores commit SHA range from agent run" do
      record = described_class.call(agent_run: agent_run)

      expect(record.commit_sha_start).to eq("aaa0000000000000000000000000000000000000")
      expect(record.commit_sha_end).to eq("bbb0000000000000000000000000000000000000")
    end

    it "creates links to agent run and issue" do
      record = described_class.call(agent_run: agent_run)

      links = record.decision_record_links
      expect(links.count).to eq(2)
      expect(links.find_by(linkable_type: "AgentRun").linkable_id).to eq(agent_run.id.to_s)
      expect(links.find_by(linkable_type: "Issue").linkable_id).to eq(issue.id.to_s)
    end

    it "returns nil when agent has no output" do
      agent_run.agent_run_logs.destroy_all
      result = described_class.call(agent_run: agent_run)
      expect(result).to be_nil
    end

    it "raises DraftFailedError when LLM returns unparseable response" do
      allow(llm_response).to receive(:output).and_return("not json")
      expect { described_class.call(agent_run: agent_run) }
        .to raise_error(described_class::DraftFailedError)
    end

    it "raises DraftFailedError when LLM response indicates failure" do
      allow(llm_response).to receive(:success?).and_return(false)
      expect { described_class.call(agent_run: agent_run) }
        .to raise_error(described_class::DraftFailedError)
    end

    it "calls AgentHarness with correct parameters" do
      described_class.call(agent_run: agent_run)

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_matching(/Decision Record/),
        provider: :claude,
        model: described_class::DEFAULT_MODEL,
        timeout: described_class::TIMEOUT,
        dangerous_mode: false,
        tools: :none
      )
    end

    it "routes the Claude provider through agent-harness text mode when an API key is configured" do
      allow(Llm::TextMode).to receive(:options).and_return(mode: :text)

      described_class.call(agent_run: agent_run)

      expect(AgentHarness).to have_received(:send_message)
        .with(anything, hash_including(provider: :claude, mode: :text))
    end

    it "does not route non-claude providers through text mode (text transport is Anthropic-only)" do
      allow(Llm::TextMode).to receive(:options).and_return(mode: :text)
      project.created_by.settings.update!(kb_chat_runner: "cursor", kb_chat_fallback_runners: [])

      described_class.call(agent_run: agent_run)

      expect(AgentHarness).to have_received(:send_message) do |_prompt, **opts|
        expect(opts[:provider]).to eq(:cursor)
        expect(opts).not_to have_key(:mode)
      end
    end

    it "uses the configured knowledge chat provider" do
      project.created_by.settings.update!(kb_chat_runner: "cursor", kb_chat_fallback_runners: [ "claude" ])

      described_class.call(agent_run: agent_run)

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_matching(/Decision Record/),
        provider: :cursor,
        timeout: described_class::TIMEOUT,
        dangerous_mode: false,
        tools: :none
      )
    end

    it "falls back to later configured knowledge chat providers" do
      project.created_by.settings.update!(kb_chat_runner: "cursor", kb_chat_fallback_runners: [ "claude" ])
      failed_response = instance_double(AgentHarness::Response, success?: false, error: "cursor unavailable")

      allow(AgentHarness).to receive(:send_message).and_return(failed_response, llm_response)

      described_class.call(agent_run: agent_run)

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_matching(/Decision Record/),
        provider: :cursor,
        timeout: described_class::TIMEOUT,
        dangerous_mode: false,
        tools: :none
      ).ordered
      expect(AgentHarness).to have_received(:send_message).with(
        a_string_matching(/Decision Record/),
        provider: :claude,
        model: described_class::DEFAULT_MODEL,
        timeout: described_class::TIMEOUT,
        dangerous_mode: false,
        tools: :none
      ).ordered
    end

    it "skips legacy unsupported configured chat providers" do
      project.created_by.settings.update_columns(
        kb_chat_runner: "not-a-provider",
        kb_chat_fallback_runners: [ "claude" ]
      )

      described_class.call(agent_run: agent_run)

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_matching(/Decision Record/),
        provider: :claude,
        model: described_class::DEFAULT_MODEL,
        timeout: described_class::TIMEOUT,
        dangerous_mode: false,
        tools: :none
      )
      expect(AgentHarness).not_to have_received(:send_message).with(
        anything,
        hash_including(provider: :"not-a-provider")
      )
    end

    it "raises DraftFailedError when LLM response is missing required fields" do
      incomplete = { title: "Missing fields", tags: %w[test] }.to_json
      allow(llm_response).to receive(:output).and_return(incomplete)

      expect { described_class.call(agent_run: agent_run) }
        .to raise_error(described_class::DraftFailedError)
    end

    it "raises DraftFailedError and logs when AgentHarness raises an error" do
      allow(AgentHarness).to receive(:send_message).and_raise(AgentHarness::Error, "timeout")

      expect { described_class.call(agent_run: agent_run) }
        .to raise_error(described_class::DraftFailedError)
    end

    it "raises DraftFailedError and logs when record creation raises RecordInvalid" do
      # Title exceeding max length after truncation would still pass, so use a
      # different approach: temporarily make the project association invalid to
      # trigger RecordInvalid from create!
      json = { title: "T", summary: "S", decision: "D", tags: [] }.to_json
      allow(llm_response).to receive(:output).and_return(json)
      allow(agent_run).to receive(:project).and_return(nil)

      expect { described_class.call(agent_run: agent_run) }
        .to raise_error(described_class::DraftFailedError)
    end
  end

  describe "containerized execution" do
    let(:mock_runner) do
      instance_double(Knowledge::AnalysisRunner)
    end

    before do
      allow(Knowledge::AnalysisRunner).to receive_messages(available?: true, supported_provider?: true, new: mock_runner)
      allow(mock_runner).to receive(:with_container).and_yield(mock_runner)
    end

    it "uses containerized path when Docker is available" do
      allow(mock_runner).to receive(:call_llm).and_return(llm_json)

      record = described_class.call(agent_run: agent_run)

      expect(record).to be_a(DecisionRecord)
      expect(record.title).to eq("Use JWT for auth")
      expect(AgentHarness).not_to have_received(:send_message)
    end

    it "creates a KnowledgeRun for tracking" do
      allow(mock_runner).to receive(:call_llm).and_return(llm_json)

      expect {
        described_class.call(agent_run: agent_run)
      }.to change(KnowledgeRun, :count).by(1)

      kr = KnowledgeRun.last
      expect(kr.operation_type).to eq("decision_drafting")
      expect(kr.project).to eq(agent_run.project)
      expect(kr.status).to eq("completed")
    end

    it "passes correct provider and model to container" do
      allow(mock_runner).to receive(:call_llm).and_return(llm_json)

      described_class.call(agent_run: agent_run)

      expect(mock_runner).to have_received(:call_llm).with(
        a_string_matching(/Decision Record/),
        provider: "claude",
        model: described_class::DEFAULT_MODEL,
        timeout: described_class::TIMEOUT
      )
    end

    it "tries fallback providers in container" do
      project.created_by.settings.update!(kb_chat_runner: "cursor", kb_chat_fallback_runners: [ "claude" ])
      allow(mock_runner).to receive(:call_llm)
        .with(anything, hash_including(provider: "cursor"))
        .and_raise(Knowledge::AnalysisRunner::ContainerError, "proxy error")
      allow(mock_runner).to receive(:call_llm)
        .with(anything, hash_including(provider: "claude"))
        .and_return(llm_json)

      record = described_class.call(agent_run: agent_run)

      expect(record).to be_a(DecisionRecord)
      expect(mock_runner).to have_received(:call_llm).twice
    end

    it "skips unsupported providers in containerized path" do
      allow(Knowledge::AnalysisRunner).to receive(:supported_provider?).with("copilot").and_return(false)
      allow(Knowledge::AnalysisRunner).to receive(:supported_provider?).with("claude").and_return(true)
      project.created_by.settings.update!(kb_chat_runner: "copilot", kb_chat_fallback_runners: [ "claude" ])
      allow(mock_runner).to receive(:call_llm).and_return(llm_json)

      record = described_class.call(agent_run: agent_run)

      expect(record).to be_a(DecisionRecord)
      expect(mock_runner).to have_received(:call_llm).with(
        anything,
        hash_including(provider: "claude")
      ).once
    end

    it "falls back to in-process when container provisioning fails" do
      allow(mock_runner).to receive(:with_container)
        .and_raise(Knowledge::AnalysisRunner::ContainerError, "no such image")

      record = described_class.call(agent_run: agent_run)

      expect(record).to be_a(DecisionRecord)
      expect(AgentHarness).to have_received(:send_message)
    end

    it "finalizes knowledge run even when container fails" do
      allow(mock_runner).to receive(:with_container)
        .and_raise(Knowledge::AnalysisRunner::ContainerError, "provision failed")

      described_class.call(agent_run: agent_run)

      kr = KnowledgeRun.last
      expect(kr).to be_present
      expect(kr.status).to eq("completed")
    end

    it "raises DraftFailedError when all containerized providers fail" do
      allow(mock_runner).to receive(:call_llm)
        .and_raise(Knowledge::AnalysisRunner::ContainerError, "proxy error")

      expect { described_class.call(agent_run: agent_run) }
        .to raise_error(described_class::DraftFailedError)
    end

    it "logs unavailable providers when only non-container providers are configured" do
      allow(Rails.logger).to receive(:warn)
      allow(Knowledge::AnalysisRunner).to receive(:supported_provider?).with("cursor").and_return(false)
      allow(Knowledge::AnalysisRunner).to receive(:supported_provider?).with("codex").and_return(false)
      project.created_by.settings.update!(kb_chat_runner: "cursor", kb_chat_fallback_runners: [ "codex" ])

      expect { described_class.call(agent_run: agent_run) }
        .to raise_error(described_class::DraftFailedError)
      expect(Rails.logger).to have_received(:warn).with(hash_including(
        message: "knowledge.providers_unavailable",
        operation: "decision_drafting",
        reason: "no_supported_container_providers",
        providers: %w[cursor codex]
      ))
      expect(KnowledgeRun.last.status).to eq("failed")
    end

    # @spec KNOWLEDGE-011
    it "persists the failure_reason on the KnowledgeRun when no container provider is supported" do
      allow(Rails.logger).to receive(:warn)
      allow(Knowledge::AnalysisRunner).to receive(:supported_provider?).with("cursor").and_return(false)
      allow(Knowledge::AnalysisRunner).to receive(:supported_provider?).with("codex").and_return(false)
      project.created_by.settings.update!(kb_chat_runner: "cursor", kb_chat_fallback_runners: [ "codex" ])

      expect { described_class.call(agent_run: agent_run) }
        .to raise_error(described_class::DraftFailedError)

      run = KnowledgeRun.last
      expect(run.failure_reason).to eq("no_supported_container_providers")
      expect(run.status).to eq("failed")
      expect(run.completed_at).to be_present
    end

    # @spec KNOWLEDGE-011
    it "annotates per-attempt outcomes for container provider failures" do
      allow(mock_runner).to receive(:call_llm)
        .and_raise(Knowledge::AnalysisRunner::ContainerError, "proxy timeout")

      expect { described_class.call(agent_run: agent_run) }
        .to raise_error(described_class::DraftFailedError)

      run = KnowledgeRun.last
      expect(run.failure_reason).to eq("containerized_providers_failed")
      expect(run.provider_attempts.last).to include(
        "provider" => "claude",
        "outcome" => "container_provider_error",
        "error_class" => "Knowledge::AnalysisRunner::ContainerError",
        "error_message" => "proxy timeout"
      )
    end

    # @spec KNOWLEDGE-011
    it "persists container_error reason on the original run when falling back to in-process" do
      allow(mock_runner).to receive(:with_container)
        .and_raise(Knowledge::AnalysisRunner::ContainerError, "provision failed")

      described_class.call(agent_run: agent_run)

      failed_runs = KnowledgeRun.where(status: "failed")
      expect(failed_runs.size).to eq(1)
      expect(failed_runs.first.failure_reason).to eq("container_error")
      expect(failed_runs.first.error_class).to eq("Knowledge::AnalysisRunner::ContainerError")
      expect(failed_runs.first.error_message).to eq("provision failed")

      expect(KnowledgeRun.last.status).to eq("completed")
    end

    # @spec KNOWLEDGE-011
    it "annotates an attempt as success when a container provider returns parseable output" do
      allow(mock_runner).to receive(:call_llm).and_return(llm_json)

      described_class.call(agent_run: agent_run)

      run = KnowledgeRun.last
      expect(run.provider_attempts.last).to include(
        "provider" => "claude",
        "outcome" => "success"
      )
      expect(run.status).to eq("completed")
    end

    # @spec KNOWLEDGE-011
    it "annotates unparseable container output as unparseable_response" do
      allow(mock_runner).to receive(:call_llm).and_return("not json")

      expect { described_class.call(agent_run: agent_run) }
        .to raise_error(described_class::DraftFailedError)

      run = KnowledgeRun.last
      expect(run.provider_attempts.last).to include(
        "provider" => "claude",
        "outcome" => "unparseable_response"
      )
      expect(run.failure_reason).to eq("containerized_providers_failed")
    end
  end

  describe "in-process fallback" do
    it "uses AgentHarness when Docker is unavailable" do
      allow(Knowledge::AnalysisRunner).to receive(:available?).and_return(false)

      record = described_class.call(agent_run: agent_run)

      expect(record).to be_a(DecisionRecord)
      expect(AgentHarness).to have_received(:send_message)
    end

    it "creates and finalizes a KnowledgeRun for in-process executor path" do
      allow(Knowledge::AnalysisRunner).to receive(:available?).and_return(false)

      expect {
        described_class.call(agent_run: agent_run)
      }.to change(KnowledgeRun, :count).by(1)

      kr = KnowledgeRun.last
      expect(kr.status).to eq("completed")
      expect(kr.operation_type).to eq("decision_drafting")
    end

    it "marks the KnowledgeRun failed when all providers fail" do
      allow(Knowledge::AnalysisRunner).to receive(:available?).and_return(false)
      allow(AgentHarness).to receive(:send_message).and_raise(AgentHarness::Error, "timeout")

      expect { described_class.call(agent_run: agent_run) }
        .to raise_error(described_class::DraftFailedError)

      expect(KnowledgeRun.last.status).to eq("failed")
    end

    it "logs provider switches for non-executor fallback paths" do
      draft = described_class.new(agent_run: agent_run)

      allow(Knowledge::AnalysisRunner).to receive(:available?).and_return(false)
      allow(Rails.logger).to receive(:warn)
      allow(draft).to receive_messages(effective_user_setting: nil, chat_providers: %w[cursor claude])
      failed_response = instance_double(AgentHarness::Response, success?: false, error: "cursor unavailable")
      allow(AgentHarness).to receive(:send_message).and_return(failed_response, llm_response)

      draft.call

      expect(Rails.logger).to have_received(:warn).with(hash_including(
        message: "knowledge.provider_switch",
        operation: "decision_drafting",
        from_provider: "cursor",
        to_provider: "claude",
        knowledge_run_id: KnowledgeRun.last.id
      ))
    end

    # @spec KNOWLEDGE-011
    it "annotates unparseable responses from in-process providers as unparseable_response" do
      draft = described_class.new(agent_run: agent_run)

      allow(Knowledge::AnalysisRunner).to receive(:available?).and_return(false)
      allow(draft).to receive_messages(effective_user_setting: nil, chat_providers: %w[cursor])
      failed_response = instance_double(AgentHarness::Response, success?: true, output: "not json")
      allow(AgentHarness).to receive(:send_message).and_return(failed_response)

      expect { draft.call }.to raise_error(described_class::DraftFailedError)

      run = KnowledgeRun.last
      expect(run.provider_attempts.last).to include(
        "provider" => "cursor",
        "outcome" => "unparseable_response"
      )
      expect(run.failure_reason).to eq("in_process_providers_failed")
    end

    # @spec KNOWLEDGE-011
    it "annotates AgentHarness errors on in-process providers with class and message" do
      draft = described_class.new(agent_run: agent_run)

      allow(Knowledge::AnalysisRunner).to receive(:available?).and_return(false)
      allow(draft).to receive_messages(effective_user_setting: nil, chat_providers: %w[cursor])
      allow(AgentHarness).to receive(:send_message)
        .and_raise(AgentHarness::ProviderError, "proxy 502")

      expect { draft.call }.to raise_error(described_class::DraftFailedError)

      run = KnowledgeRun.last
      expect(run.provider_attempts.last).to include(
        "provider" => "cursor",
        "outcome" => "provider_error",
        "error_class" => "AgentHarness::ProviderError",
        "error_message" => "proxy 502"
      )
      expect(run.failure_reason).to eq("in_process_providers_failed")
      expect(run.error_class).to eq("AgentHarness::ProviderError")
    end

    # @spec KNOWLEDGE-011
    it "preserves unparseable_response when the executor raises ProviderError for the same attempt" do
      allow(Knowledge::AnalysisRunner).to receive(:available?).and_return(false)
      allow(AgentHarness).to receive(:send_message).and_return(
        instance_double(AgentHarness::Response, success?: true, output: "not json")
      )

      expect { described_class.call(agent_run: agent_run) }
        .to raise_error(described_class::DraftFailedError)

      run = KnowledgeRun.last
      expect(run.provider_attempts.last).to include(
        "provider" => "claude",
        "outcome" => "unparseable_response",
        "error_class" => "AgentHarness::ProviderError",
        "error_message" => "Runner claude returned unparseable response"
      )
      expect(run.failure_reason).to eq("all_providers_exhausted")
    end

    # @spec KNOWLEDGE-011
    it "persists all_providers_exhausted when the executor path exhausts all runners" do
      allow(Knowledge::AnalysisRunner).to receive(:available?).and_return(false)
      allow(AgentHarness).to receive(:send_message).and_raise(AgentHarness::Error, "timeout")

      expect { described_class.call(agent_run: agent_run) }
        .to raise_error(described_class::DraftFailedError)

      run = KnowledgeRun.last
      expect(run.status).to eq("failed")
      expect(run.failure_reason).to eq("all_providers_exhausted")
      expect(run.error_class).to eq("AgentHarness::Error")
      expect(run.error_message).to include("timeout")
    end
  end
end
