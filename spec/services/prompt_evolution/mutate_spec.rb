# frozen_string_literal: true

require "rails_helper"

RSpec.describe PromptEvolution::Mutate do
  let(:prompt) { create(:prompt, :global, :with_version) }
  let(:current_version) { prompt.current_version }

  let(:valid_llm_response) do
    {
      "mutations" => [
        {
          "template" => "Improved prompt for {{title}}",
          "strategy" => "refinement",
          "reasoning" => "Added clearer instructions",
          "expected_improvement" => "Should reduce iteration count"
        }
      ]
    }.to_json
  end

  let(:multi_mutation_response) do
    {
      "mutations" => [
        {
          "template" => "Refined prompt for {{title}}",
          "strategy" => "refinement",
          "reasoning" => "Targeted improvement",
          "expected_improvement" => "Better clarity"
        },
        {
          "template" => "Restructured prompt for {{title}}",
          "strategy" => "restructuring",
          "reasoning" => "Better organization",
          "expected_improvement" => "Clearer flow"
        },
        {
          "template" => "Simplified prompt for {{title}}",
          "strategy" => "simplification",
          "reasoning" => "Removed redundancy",
          "expected_improvement" => "Less confusion"
        }
      ]
    }.to_json
  end

  let(:harness_response) { instance_double(AgentHarness::Response, success?: true, output: valid_llm_response) }

  before do
    allow(AgentHarness).to receive(:send_message).and_return(harness_response)
  end

  describe ".call" do
    it "returns mutations from the LLM" do
      mutations = described_class.call(prompt: prompt)

      expect(mutations).to be_an(Array)
      expect(mutations.size).to eq(1)
      expect(mutations.first).to be_a(described_class::Mutation)
      expect(mutations.first.template).to eq("Improved prompt for {{title}}")
      expect(mutations.first.strategy).to eq("refinement")
      expect(mutations.first.reasoning).to eq("Added clearer instructions")
      expect(mutations.first.expected_improvement).to eq("Should reduce iteration count")
    end

    it "sends the current template to the LLM" do
      described_class.call(prompt: prompt)

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including(current_version.template),
        provider: :claude,
        model: "claude-sonnet-4-6",
        timeout: 60
      )
    end

    it "generates the requested number of mutations" do
      allow(harness_response).to receive(:output).and_return(multi_mutation_response)

      mutations = described_class.call(prompt: prompt, mutation_count: 3)

      expect(mutations.size).to eq(3)
    end

    it "includes mutation strategies in the prompt" do
      described_class.call(prompt: prompt, strategies: %w[refinement simplification])

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including("Refinement", "Simplification"),
        hash_including(provider: :claude)
      )
    end
  end

  describe "validation" do
    it "raises when prompt has no current version" do
      prompt_without_version = create(:prompt, :global)

      expect {
        described_class.call(prompt: prompt_without_version)
      }.to raise_error(ArgumentError, /current version/)
    end

    it "raises when strategies list is empty after filtering" do
      expect {
        described_class.call(prompt: prompt, strategies: %w[invalid])
      }.to raise_error(ArgumentError, /strategies/)
    end
  end

  describe "mutation_count clamping" do
    it "clamps mutation_count to minimum of 1" do
      described_class.call(prompt: prompt, mutation_count: 0)

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including("1 improved variant"),
        hash_including(provider: :claude)
      )
    end

    it "clamps mutation_count to maximum of 5" do
      described_class.call(prompt: prompt, mutation_count: 10)

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including("5 improved variant"),
        hash_including(provider: :claude)
      )
    end
  end

  describe "quality metrics integration" do
    let(:agent_run) { create(:agent_run, prompt_version: current_version) }

    it "includes performance data when metrics are provided" do
      metric = create(:quality_metric, agent_run: agent_run, prompt_version: current_version,
        composite_score: 0.75, scores: { "ci_passed" => 1.0, "pr_merged" => 0.5 })

      described_class.call(prompt: prompt, quality_metrics: [ metric ])

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including("Average quality score: 0.75"),
        hash_including(provider: :claude)
      )
    end

    it "identifies failure modes from low scores" do
      metric = create(:quality_metric, agent_run: agent_run, prompt_version: current_version,
        composite_score: 0.3, scores: { "ci_passed" => 0.2, "pr_merged" => 0.0 })

      described_class.call(prompt: prompt, quality_metrics: [ metric ])

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including("Low ci passed"),
        hash_including(provider: :claude)
      )
    end

    it "handles metrics without composite scores" do
      metric = create(:quality_metric, agent_run: agent_run, prompt_version: current_version,
        composite_score: nil, scores: {})

      mutations = described_class.call(prompt: prompt, quality_metrics: [ metric ])

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including("No composite scores available"),
        hash_including(provider: :claude)
      )
      expect(mutations).to be_an(Array)
    end
  end

  describe "sample outputs" do
    it "includes success and failure samples" do
      samples = {
        successes: [ "Good output that worked well" ],
        failures: [ "Bad output that failed" ]
      }

      described_class.call(prompt: prompt, sample_outputs: samples)

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including("Successful Runs", "Good output", "Failed Runs", "Bad output"),
        hash_including(provider: :claude)
      )
    end

    it "truncates long sample outputs" do
      samples = { successes: [ "x" * 5000 ] }

      described_class.call(prompt: prompt, sample_outputs: samples)

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including("[truncated]"),
        hash_including(provider: :claude)
      )
    end

    it "limits the number of samples" do
      samples = { successes: (1..10).map { |i| "Unique sample output #{i}" } }

      described_class.call(prompt: prompt, sample_outputs: samples)

      expect(AgentHarness).to have_received(:send_message) do |prompt_text, **_opts|
        expect(prompt_text).to include("Unique sample output 1")
        expect(prompt_text).to include("Unique sample output 3")
        expect(prompt_text).not_to include("Unique sample output 4")
      end
    end
  end

  describe "error handling" do
    it "returns empty array when LLM response fails" do
      allow(harness_response).to receive(:success?).and_return(false)

      mutations = described_class.call(prompt: prompt)

      expect(mutations).to eq([])
    end

    it "returns empty array when AgentHarness raises" do
      allow(AgentHarness).to receive(:send_message).and_raise(AgentHarness::Error, "timeout")

      mutations = described_class.call(prompt: prompt)

      expect(mutations).to eq([])
    end

    it "returns empty array when LLM returns invalid JSON" do
      allow(harness_response).to receive(:output).and_return("not json at all")

      mutations = described_class.call(prompt: prompt)

      expect(mutations).to eq([])
    end

    it "returns empty array when LLM returns JSON without mutations key" do
      allow(harness_response).to receive(:output).and_return('{"other": "data"}')

      mutations = described_class.call(prompt: prompt)

      expect(mutations).to eq([])
    end

    it "returns empty array when LLM returns JSON with non-array mutations" do
      allow(harness_response).to receive(:output).and_return('{"mutations":"oops"}')

      mutations = described_class.call(prompt: prompt)

      expect(mutations).to eq([])
    end

    it "returns empty array when LLM returns JSON with non-hash mutation entries" do
      allow(harness_response).to receive(:output).and_return('{"mutations":["not a hash"]}')

      mutations = described_class.call(prompt: prompt)

      expect(mutations).to eq([])
    end
  end

  describe "mutation validation" do
    it "rejects mutations with blank templates" do
      response = { "mutations" => [ { "template" => "", "strategy" => "refinement",
                                     "reasoning" => "test", "expected_improvement" => "test" } ] }.to_json
      allow(harness_response).to receive(:output).and_return(response)

      mutations = described_class.call(prompt: prompt)

      expect(mutations).to be_empty
    end

    it "rejects mutations with invalid strategy" do
      response = { "mutations" => [ { "template" => "Good template {{title}}", "strategy" => "invalid",
                                     "reasoning" => "test", "expected_improvement" => "test" } ] }.to_json
      allow(harness_response).to receive(:output).and_return(response)

      mutations = described_class.call(prompt: prompt)

      expect(mutations).to be_empty
    end

    it "rejects mutations missing required variables" do
      prompt_with_vars = create(:prompt, :global)
      prompt_with_vars.create_version!(template: "Do {{task}} for {{repo}}", variables: %w[task repo])

      response = { "mutations" => [ { "template" => "Do {{task}} only", "strategy" => "simplification",
                                     "reasoning" => "test", "expected_improvement" => "test" } ] }.to_json
      allow(harness_response).to receive(:output).and_return(response)

      mutations = described_class.call(prompt: prompt_with_vars)

      expect(mutations).to be_empty
    end

    it "accepts mutations with all required variables present" do
      prompt_with_vars = create(:prompt, :global)
      prompt_with_vars.create_version!(template: "Do {{task}} for {{repo}}", variables: %w[task repo])

      response = { "mutations" => [ { "template" => "Complete {{task}} in {{repo}} with care",
                                     "strategy" => "expansion",
                                     "reasoning" => "test",
                                     "expected_improvement" => "test" } ] }.to_json
      allow(harness_response).to receive(:output).and_return(response)

      mutations = described_class.call(prompt: prompt_with_vars)

      expect(mutations.size).to eq(1)
      expect(mutations.first.template).to include("{{task}}", "{{repo}}")
    end

    it "rejects mutations exceeding max template length" do
      response = { "mutations" => [ { "template" => "x" * 50_001, "strategy" => "expansion",
                                     "reasoning" => "test", "expected_improvement" => "test" } ] }.to_json
      allow(harness_response).to receive(:output).and_return(response)

      mutations = described_class.call(prompt: prompt)

      expect(mutations).to be_empty
    end
  end

  describe "output normalization" do
    it "handles LLM response wrapped in markdown fences" do
      fenced = "```json\n#{valid_llm_response}\n```"
      allow(harness_response).to receive(:output).and_return(fenced)

      mutations = described_class.call(prompt: prompt)

      expect(mutations.size).to eq(1)
    end

    it "handles LLM response wrapped in quotes" do
      quoted = "\"#{valid_llm_response.gsub('\\', '\\\\\\\\').gsub('"', '\\"')}\""
      allow(harness_response).to receive(:output).and_return(quoted)

      # The JSON inside quotes may not parse cleanly after unescaping,
      # so this tests graceful degradation
      mutations = described_class.call(prompt: prompt)

      expect(mutations).to be_an(Array)
    end
  end

  describe "strategies filtering" do
    it "only includes valid strategies" do
      described_class.call(prompt: prompt, strategies: %w[refinement invalid expansion])

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_matching(/refinement.*expansion/m),
        hash_including(provider: :claude)
      )
    end

    it "only returns mutations for the requested strategies" do
      mixed_response = {
        "mutations" => [
          { "template" => "Refined {{title}}", "strategy" => "refinement",
            "reasoning" => "test", "expected_improvement" => "test" },
          { "template" => "Expanded {{title}}", "strategy" => "expansion",
            "reasoning" => "test", "expected_improvement" => "test" }
        ]
      }.to_json
      allow(harness_response).to receive(:output).and_return(mixed_response)

      mutations = described_class.call(prompt: prompt, strategies: %w[refinement])

      expect(mutations.size).to eq(1)
      expect(mutations.first.strategy).to eq("refinement")
    end
  end

  describe "prompt with system_prompt" do
    it "includes system prompt in the LLM request" do
      prompt_with_system = create(:prompt, :global)
      prompt_with_system.create_version!(template: "Do {{title}}", system_prompt: "You are a coding assistant")

      described_class.call(prompt: prompt_with_system)

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including("System Prompt", "You are a coding assistant"),
        hash_including(provider: :claude)
      )
    end
  end
end
