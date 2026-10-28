# frozen_string_literal: true

require "rails_helper"

# @spec KNOWLEDGE-010
RSpec.describe Knowledge::Decisions::Draft do
  before do
    configure_llm_routing(project: project)
    owner = project.effective_owner
    unless owner.runners.kept_only.where(runner_key: "cursor").exists?
      create(:runner, user: owner, runner_key: "cursor")
    end
    project.effective_owner.runners.kept_only.subscription.each do |runner|
      runner.update!(enabled_for_chat: true, tier_models: { "mid" => { "model_id" => "configured-mid", "provider_id" => 17 } })
    end
allow(AgentHarness.conductor).to receive(:execute_direct).and_return(llm_response)
    agent_run.log!("stdout", "Implemented JWT authentication for API endpoints")
  end

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

    # @spec LLM-ROUTING-007
    it "rejects a JSON array instead of crashing during persistence" do
      allow(llm_response).to receive(:output).and_return("[]")

      expect { described_class.call(agent_run: agent_run) }
        .to raise_error(described_class::DraftFailedError)
      expect(DecisionRecord.where(agent_run: agent_run)).to be_empty
    end

    # @spec LLM-ROUTING-007
    it "does not try another runner when fallback is disabled" do
      owner = project.effective_owner
      owner.settings.update!(kb_chat_runner: "cursor", kb_chat_fallback_runners: [ "claude" ], fallback_enabled: false)
      allow(AgentHarness.conductor).to receive(:execute_direct)
        .with(anything, hash_including(provider: :cursor)).and_raise(AgentHarness::AuthenticationError, "Unavailable")

      expect { described_class.call(agent_run: agent_run) }.to raise_error(described_class::DraftFailedError)
      expect(AgentHarness.conductor).not_to have_received(:execute_direct).with(anything, hash_including(provider: :claude))
    end

    it "raises DraftFailedError when LLM response indicates failure" do
      allow(llm_response).to receive(:success?).and_return(false)
      expect { described_class.call(agent_run: agent_run) }
        .to raise_error(described_class::DraftFailedError)
    end

    it "calls AgentHarness with correct parameters" do
      described_class.call(agent_run: agent_run)

      expect(AgentHarness.conductor).to have_received(:execute_direct).with(
        a_string_matching(/Decision Record/), hash_including(provider: :claude,
        model: "configured-mid",
        timeout: described_class::TIMEOUT,
        dangerous_mode: false,
        tools: :none))
    end

    # @spec KNOWLEDGE-CREDENTIAL-001
    it "uses the API credential on the selected runner" do
      owner = project.effective_owner
      key = create(:provider_api_key, user: owner, api_service_type: "anthropic", api_key: "sk-selected")
      runner = create(:runner, :api_key, user: owner, runner_key: "claude", provider_api_key: key,
        tier_models: { "mid" => { "model_id" => "configured-mid", "provider_id" => 17 } })
      owner.settings.update!(kb_chat_runner: runner.routing_key)
      transport = instance_double(AgentHarness::Api::ChatTransport, call: { status: :succeeded, content: llm_json })
      allow(AgentHarness::Api::ChatTransport).to receive(:new).and_return(transport)

      described_class.call(agent_run: agent_run)

      expect(transport).to have_received(:call) do |request|
        expect(request[:candidates].first).to include(credentials: { api_key: key.api_key })
      end
    end

    it "does not route non-claude providers through text mode (text transport is Anthropic-only)" do
      project.created_by.settings.update!(kb_chat_runner: "cursor", kb_chat_fallback_runners: [])

      described_class.call(agent_run: agent_run)

      expect(AgentHarness.conductor).to have_received(:execute_direct) do |_prompt, **opts|
        expect(opts[:provider]).to eq(:cursor)
        expect(opts).not_to have_key(:mode)
      end
    end

    it "uses the configured knowledge chat provider" do
      project.created_by.settings.update!(kb_chat_runner: "cursor", kb_chat_fallback_runners: [ "claude" ])

      described_class.call(agent_run: agent_run)

      expect(AgentHarness.conductor).to have_received(:execute_direct).with(
        a_string_matching(/Decision Record/), hash_including(provider: :cursor,
        timeout: described_class::TIMEOUT,
        dangerous_mode: false,
        tools: :none))
    end

    it "falls back to later configured knowledge chat providers" do
      project.created_by.settings.update!(kb_chat_runner: "cursor", kb_chat_fallback_runners: [ "claude" ], fallback_enabled: true)
      failed_response = instance_double(AgentHarness::Response, success?: false, error: "cursor unavailable")

      allow(AgentHarness.conductor).to receive(:execute_direct).and_return(failed_response, llm_response)

      described_class.call(agent_run: agent_run)

      expect(AgentHarness.conductor).to have_received(:execute_direct).with(
        a_string_matching(/Decision Record/), hash_including(provider: :cursor,
        timeout: described_class::TIMEOUT,
        dangerous_mode: false,
        tools: :none)).ordered
      expect(AgentHarness.conductor).to have_received(:execute_direct).with(
        a_string_matching(/Decision Record/), hash_including(provider: :claude,
        model: "configured-mid",
        timeout: described_class::TIMEOUT,
        dangerous_mode: false,
        tools: :none)).ordered
    end

    it "skips legacy unsupported configured chat providers" do
      project.created_by.settings.update_columns(
        kb_chat_runner: "not-a-provider",
        kb_chat_fallback_runners: [ "claude" ]
      )

      described_class.call(agent_run: agent_run)

      expect(AgentHarness.conductor).to have_received(:execute_direct).with(
        a_string_matching(/Decision Record/), hash_including(provider: :claude,
        model: "configured-mid",
        timeout: described_class::TIMEOUT,
        dangerous_mode: false,
        tools: :none))
      expect(AgentHarness.conductor).not_to have_received(:execute_direct).with(
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
      allow(AgentHarness.conductor).to receive(:execute_direct).and_raise(AgentHarness::Error, "timeout")

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

  describe "decision supersession" do
    let(:existing) do
      create(:decision_record, :without_agent_run,
        project: project,
        title: "Use Postgres advisory locks for queue fairness",
        decision: "Queue fairness is enforced with Postgres advisory locks.")
    end

    def superseding_json(supersedes_ids)
      {
        title: "Move queue fairness to Redis",
        summary: "Decided to move queue fairness to Redis.",
        context: "Advisory locks coupled queue fairness to the primary database.",
        decision: "Queue fairness moves to Redis.",
        consequences: "Adds a Redis dependency for queueing.",
        tags: %w[queue redis],
        supersedes_ids: supersedes_ids
      }.to_json
    end

    # @spec KNOWLEDGE-012
    it "presents existing active decision records to the drafting LLM" do
      existing
      described_class.call(agent_run: agent_run)

      expect(AgentHarness.conductor).to have_received(:execute_direct).with(
        a_string_including("[#{existing.id}] Use Postgres advisory locks for queue fairness"),
        kind_of(Hash)
      )
    end

    # @spec KNOWLEDGE-012
    it "excludes superseded records and other projects' records from the prompt" do
      existing
      create(:decision_record, :without_agent_run, project: project, status: "superseded",
        title: "Run everything through the primary database")
      create(:decision_record, :without_agent_run, title: "Use SQLite everywhere")

      described_class.call(agent_run: agent_run)

      expect(AgentHarness.conductor).to have_received(:execute_direct) do |prompt, **_opts|
        expect(prompt).to include("[#{existing.id}] Use Postgres advisory locks for queue fairness")
        expect(prompt).not_to include("Run everything through the primary database")
        expect(prompt).not_to include("Use SQLite everywhere")
      end
    end

    # @spec KNOWLEDGE-012
    it "supersedes referenced records when the LLM returns supersedes_ids" do
      allow(llm_response).to receive(:output).and_return(superseding_json([ existing.id ]))

      record = described_class.call(agent_run: agent_run)

      existing.reload
      expect(existing.status).to eq("superseded")
      expect(existing.superseded_by_id).to eq(record.id)
      expect(record.decision_record_links.find_by(link_type: "reverts")).to be_present
    end

    # @spec KNOWLEDGE-012
    it "keeps the draft successful when supersedes references are unresolvable" do
      existing
      allow(llm_response).to receive(:output).and_return(superseding_json([ 999_999 ]))

      record = nil
      expect { record = described_class.call(agent_run: agent_run) }.not_to raise_error

      expect(record).to be_persisted
      expect(record.status).to eq("active")
      expect(existing.reload.status).to eq("active")
    end

    # @spec KNOWLEDGE-012
    it "does not supersede records belonging to another project" do
      other = create(:decision_record, :without_agent_run, title: "Use SQLite everywhere")
      allow(llm_response).to receive(:output).and_return(superseding_json([ other.id ]))

      described_class.call(agent_run: agent_run)

      expect(other.reload.status).to eq("active")
    end

    # @spec KNOWLEDGE-012
    it "marks the prompt as having no existing records when the corpus is empty" do
      allow(llm_response).to receive(:output).and_return(superseding_json([]))

      described_class.call(agent_run: agent_run)

      expect(AgentHarness.conductor).to have_received(:execute_direct).with(
        a_string_including("(none)"),
        kind_of(Hash)
      )
    end
  end

  describe "in-process fallback" do
    it "uses AgentHarness when Docker is unavailable" do
      record = described_class.call(agent_run: agent_run)

      expect(record).to be_a(DecisionRecord)
      expect(AgentHarness.conductor).to have_received(:execute_direct)
    end

    it "creates and finalizes a KnowledgeRun for in-process executor path" do
      expect {
        described_class.call(agent_run: agent_run)
      }.to change(KnowledgeRun, :count).by(1)

      kr = KnowledgeRun.last
      expect(kr.status).to eq("completed")
      expect(kr.operation_type).to eq("decision_drafting")
    end

    it "marks the KnowledgeRun failed when all providers fail" do
      allow(AgentHarness.conductor).to receive(:execute_direct).and_raise(AgentHarness::Error, "timeout")

      expect { described_class.call(agent_run: agent_run) }
        .to raise_error(described_class::DraftFailedError)

      expect(KnowledgeRun.last.status).to eq("failed")
    end

    it "logs provider switches for non-executor fallback paths" do
      draft = described_class.new(agent_run: agent_run)

      allow(Rails.logger).to receive(:warn)
      project.effective_owner.settings.update!(kb_chat_runner: "cursor", kb_chat_fallback_runners: [ "claude" ], fallback_enabled: true)
      failed_response = instance_double(AgentHarness::Response, success?: false, error: "cursor unavailable")
      allow(AgentHarness.conductor).to receive(:execute_direct).and_return(failed_response, llm_response)

      draft.call

      expect(Rails.logger).to have_received(:warn).with(hash_including(
        message: "knowledge.provider_switch",
        operation: "decision_drafting",
        from_provider: project.effective_owner.runners.find_by!(runner_key: "cursor").routing_key,
        to_provider: project.effective_owner.runners.find_by!(runner_key: "claude").routing_key,
        knowledge_run_id: KnowledgeRun.last.id
      ))
    end

    # @spec KNOWLEDGE-011
    it "annotates unparseable responses from in-process providers as unparseable_response" do
      draft = described_class.new(agent_run: agent_run)

      project.effective_owner.settings.update!(kb_chat_runner: "cursor", fallback_enabled: false)
      failed_response = instance_double(AgentHarness::Response, success?: true, output: "not json")
      allow(AgentHarness.conductor).to receive(:execute_direct).and_return(failed_response)

      expect { draft.call }.to raise_error(described_class::DraftFailedError)

      run = KnowledgeRun.last
      expect(run.provider_attempts.last).to include(
        "provider" => project.effective_owner.runners.find_by!(runner_key: "cursor").routing_key,
        "outcome" => "unparseable_response"
      )
      expect(run.failure_reason).to eq("all_providers_exhausted")
    end

    # @spec KNOWLEDGE-011
    it "annotates AgentHarness errors on in-process providers with class and message" do
      draft = described_class.new(agent_run: agent_run)

      project.effective_owner.settings.update!(kb_chat_runner: "cursor", fallback_enabled: false)
      allow(AgentHarness.conductor).to receive(:execute_direct)
        .and_raise(AgentHarness::ProviderError, "proxy 502")

      expect { draft.call }.to raise_error(described_class::DraftFailedError)

      run = KnowledgeRun.last
      expect(run.provider_attempts.last).to include(
        "provider" => project.effective_owner.runners.find_by!(runner_key: "cursor").routing_key,
        "outcome" => "provider_error",
        "error_class" => "AgentHarness::ProviderError",
        "error_message" => "proxy 502"
      )
      expect(run.failure_reason).to eq("all_providers_exhausted")
      expect(run.error_class).to eq("AgentHarness::ProviderError")
    end

    # @spec KNOWLEDGE-011
    it "persists all_providers_exhausted when the executor path exhausts all runners" do
      allow(AgentHarness.conductor).to receive(:execute_direct).and_raise(AgentHarness::Error, "timeout")

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
