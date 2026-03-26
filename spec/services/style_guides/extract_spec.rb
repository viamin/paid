# frozen_string_literal: true

require "rails_helper"

RSpec.describe StyleGuides::Extract do
  let(:project) { create(:project) }

  let(:ruby_samples) do
    [ { path: "app/models/user.rb", content: "class User\nend" } ]
  end

  let(:ts_samples) do
    [ { path: "src/index.ts", content: "export const foo = 1;" } ]
  end

  let(:collected_samples) do
    { "ruby" => ruby_samples, "typescript" => ts_samples }
  end

  let(:llm_response) do
    AgentHarness::Response.new(
      output: "- Use snake_case for methods\n- Use CamelCase for classes",
      exit_code: 0,
      duration: 2.5,
      provider: :claude,
      model: "claude-sonnet-4-6",
      tokens: { input: 500, output: 100, total: 600 }
    )
  end

  before do
    allow(StyleGuides::CollectCodeSamples).to receive(:call).and_return(collected_samples)
    allow(AgentHarness).to receive(:send_message).and_return(llm_response)
  end

  describe ".call" do
    it "creates style guides for each detected language" do
      result = described_class.call(project: project)

      expect(result.style_guides.length).to eq(2)
      expect(result.languages).to contain_exactly("ruby", "typescript")
    end

    it "creates project-level style guides" do
      result = described_class.call(project: project)

      result.style_guides.each do |guide|
        expect(guide.project).to eq(project)
        expect(guide.account).to eq(project.account)
        expect(guide.active).to be true
      end
    end

    it "names guides with language and auto-extracted label" do
      result = described_class.call(project: project)

      names = result.style_guides.map(&:name)
      expect(names).to contain_exactly(
        "Ruby Style Guide (auto-extracted)",
        "TypeScript Style Guide (auto-extracted)"
      )
    end

    it "stores LLM output as raw_content" do
      result = described_class.call(project: project)

      result.style_guides.each do |guide|
        expect(guide.raw_content).to eq("- Use snake_case for methods\n- Use CamelCase for classes")
      end
    end

    it "enqueues compression jobs for each guide" do
      expect {
        described_class.call(project: project)
      }.to have_enqueued_job(StyleGuideCompressionJob).exactly(2).times
    end

    it "calls LLM with extraction prompt including code samples" do
      described_class.call(project: project)

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including("ruby").and(a_string_including("class User")),
        provider: :claude,
        model: "claude-sonnet-4-6",
        timeout: 120,
        dangerous_mode: false
      )
    end

    it "returns empty result when no samples are collected" do
      allow(StyleGuides::CollectCodeSamples).to receive(:call).and_return({})

      result = described_class.call(project: project)

      expect(result.any_extracted?).to be false
      expect(result.style_guides).to be_empty
    end

    it "updates existing auto-extracted guide instead of creating duplicate" do
      create(:style_guide, :for_project, project: project, account: project.account,
        name: "Ruby Style Guide (auto-extracted)", language: "ruby")

      expect {
        described_class.call(project: project)
      }.to change(StyleGuide, :count).by(1) # only typescript is new

      ruby_guide = project.style_guides.find_by(name: "Ruby Style Guide (auto-extracted)")
      expect(ruby_guide.raw_content).to eq("- Use snake_case for methods\n- Use CamelCase for classes")
    end

    context "when LLM returns empty output" do
      let(:llm_response) do
        AgentHarness::Response.new(
          output: "",
          exit_code: 0,
          duration: 2.5,
          provider: :claude,
          model: "claude-sonnet-4-6",
          tokens: { input: 500, output: 0, total: 500 }
        )
      end

      it "raises ExtractionError" do
        expect {
          described_class.call(project: project)
        }.to raise_error(StyleGuides::ExtractionError)
      end
    end
  end
end
