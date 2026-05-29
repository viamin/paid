# frozen_string_literal: true

require "rails_helper"

RSpec.describe RunProvenanceBuilder do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:agent_run) { create(:agent_run, project: project, agent_type: "claude_code") }
  let(:service_environment_prompt_blocks) do
    [
      {
        slug: Prompts::ServiceContainerSections::RUBY_DB_SETUP_SLUG,
        prompt_id: 12,
        prompt_version_id: 34,
        version_number: 2,
        source: "versioned"
      },
      {
        slug: Prompts::ServiceContainerSections::AVAILABLE_SERVICES_INTRO_SLUG,
        prompt_id: nil,
        prompt_version_id: nil,
        version_number: nil,
        source: "fallback"
      }
    ]
  end

  it "builds a provenance hash with all categories" do
    provenance = described_class.new(agent_run).build

    expect(provenance).to include(:run, :prompt, :model, :tools, :code_changes, :approvals,
                                  :timeline, :costs, :runner_attempts)
  end

  it "includes run summary" do
    provenance = described_class.new(agent_run).build

    expect(provenance[:run]).to include(:id, :agent_type, :goal, :status, :trigger_type)
    expect(provenance[:run][:id]).to eq(agent_run.id)
  end

  it "handles nil prompt version" do
    provenance = described_class.new(agent_run).build

    expect(provenance[:prompt][:source]).to eq("none")
    expect(provenance[:prompt][:prompt_version_id]).to be_nil
  end

  it "includes prompt provenance when prompt_version is set" do
    prompt = create(:prompt, account: account, project: project)
    prompt_version = create(:prompt_version, prompt: prompt, version: 3)
    agent_run.update!(prompt_version: prompt_version)

    provenance = described_class.new(agent_run.reload).build

    expect(provenance[:prompt][:source]).to eq("versioned")
    expect(provenance[:prompt][:prompt_slug]).to eq(prompt.slug)
    expect(provenance[:prompt][:version_number]).to eq(3)
  end

  it "includes service environment prompt provenance from create_agent_run metadata" do
    agent_run.agent_run_phases.create!(
      phase_key: "create_agent_run",
      phase_group: "prompt",
      started_at: 1.minute.ago,
      finished_at: 30.seconds.ago,
      duration_seconds: 30,
      metadata: { service_environment_prompt_blocks: service_environment_prompt_blocks }
    )

    provenance = described_class.new(agent_run.reload).build

    expect(provenance[:prompt][:service_environment_prompt_blocks]).to eq(service_environment_prompt_blocks)
  end

  it "handles nil model_selection" do
    provenance = described_class.new(agent_run).build

    expect(provenance[:model][:selector_type]).to be_nil
  end

  it "includes tool provenance with snapshot" do
    run = create(:agent_run, project: project, agent_type: "claude_code")

    provenance = described_class.new(run).build

    expect(provenance[:tools]).to include(:servers_count, :servers, :provisioned_servers_count, :sidecar_container_ids)
  end

  it "includes code change provenance" do
    agent_run.update!(pull_request_url: "https://github.com/owner/repo/pull/5")

    provenance = described_class.new(agent_run.reload).build

    expect(provenance[:code_changes][:pull_request_url]).to eq("https://github.com/owner/repo/pull/5")
  end

  it "includes timeline from phases" do
    agent_run.agent_run_phases.create!(phase_key: "setup", phase_group: "setup",
                                        started_at: 1.minute.ago, finished_at: 30.seconds.ago,
                                        duration_seconds: 30)

    provenance = described_class.new(agent_run.reload).build

    expect(provenance[:timeline].length).to eq(1)
    expect(provenance[:timeline].first[:phase_key]).to eq("setup")
  end

  it "returns nil for approvals when no prompt version" do
    provenance = described_class.new(agent_run).build

    expect(provenance[:approvals]).to be_nil
  end

  it "includes cost provenance" do
    provenance = described_class.new(agent_run).build

    expect(provenance[:costs]).to include(:tokens_input, :tokens_output, :cost_cents)
  end

  it "includes runner attempt provenance" do
    provenance = described_class.new(agent_run).build

    expect(provenance[:runner_attempts]).to include(:final_runner, :runner_switches, :attempts)
  end
end
