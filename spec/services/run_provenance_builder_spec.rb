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
  let(:prompt_assembly_metadata) do
    {
      "prompt_assembly" => {
        "sections" => [
          { "key" => "task", "source" => "build_for_pr", "trust_level" => "trusted",
            "required" => true, "inclusion_reason" => "core task" },
          { "key" => "knowledge", "source" => "context_bundle", "trust_level" => "quarantined",
            "required" => false, "inclusion_reason" => "repo context" }
        ],
        "skipped" => [
          { "key" => "comments", "source" => "conversation", "trust_level" => "excluded",
            "reason" => "author_not_in_allowlist" }
        ],
        "prompt_digest" => "abc123def456",
        "profile_fingerprint" => "fingerprint789",
        "budget_decisions" => [ { "section" => "knowledge", "budget" => { "tokens" => 4000 } } ]
      }
    }
  end

  it "builds a provenance hash with all categories" do
    provenance = described_class.new(agent_run).build

    expect(provenance).to include(:run, :prompt, :prompt_assembly, :model, :tools, :code_changes,
                                  :approvals, :timeline, :costs, :runner_attempts)
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

  it "includes service environment prompt provenance from prepare_pr_prompt metadata" do
    agent_run.agent_run_phases.create!(
      phase_key: "prepare_pr_prompt",
      phase_group: "prompt",
      started_at: 1.minute.ago,
      finished_at: 30.seconds.ago,
      duration_seconds: 30,
      metadata: { service_environment_prompt_blocks: service_environment_prompt_blocks }
    )

    provenance = described_class.new(agent_run.reload).build

    expect(provenance[:prompt][:service_environment_prompt_blocks]).to eq(service_environment_prompt_blocks)
  end

  # @spec PROMPT-ASSEMBLY-013
  it "includes prompt assembly provenance when metadata exists" do
    create_prompt_assembly_phase!(prompt_assembly_metadata)
    provenance = described_class.new(agent_run.reload).build

    pa = provenance[:prompt_assembly]
    expect(pa).to be_a(Hash)
    expect(pa[:sections].size).to eq(2)
    expect(pa[:skipped].size).to eq(1)
    expect(pa[:prompt_digest]).to eq("abc123def456")
    expect(pa[:profile_fingerprint]).to eq("fingerprint789")
    expect(pa[:budget_decisions]).to be_an(Array)
    expect(pa[:trusted_content_count]).to eq(1)
    expect(pa[:quarantined_content_count]).to eq(1)
    expect(pa[:excluded_content_count]).to eq(1)
  end

  def create_prompt_assembly_phase!(metadata)
    agent_run.agent_run_phases.create!(
      phase_key: "prepare_pr_prompt",
      phase_group: "prompt",
      started_at: 1.minute.ago,
      finished_at: 30.seconds.ago,
      duration_seconds: 30,
      metadata: metadata
    )
  end

  it "returns nil prompt_assembly when no assembly metadata exists" do
    provenance = described_class.new(agent_run).build

    expect(provenance[:prompt_assembly]).to be_nil
  end

  # @spec PROMPT-ASSEMBLY-010
  it "surfaces prompt assembly provenance recorded on the run" do
    assembly = { "digest" => "abc123", "sections" => [ { "key" => "goal.review" } ] }
    agent_run.update!(external_metadata: (agent_run.external_metadata || {}).merge("prompt_assembly" => assembly))

    provenance = described_class.new(agent_run.reload).build

    expect(provenance[:prompt][:assembly]).to eq(assembly)
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
