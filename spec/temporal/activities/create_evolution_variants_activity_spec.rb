# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CreateEvolutionVariantsActivity do
  let(:activity) { described_class.new }

  describe "class" do
    it "inherits from BaseActivity" do
      expect(described_class.superclass).to eq(Activities::BaseActivity)
    end
  end

  describe "#execute" do
    let(:prompt) { create(:prompt, :global, :with_version) }

    let(:mutations_data) do
      [
        {
          template: "Improved prompt for {{title}}",
          strategy: "refinement",
          reasoning: "better instructions",
          expected_improvement: "higher quality"
        }
      ]
    end

    let(:input) do
      { prompt_id: prompt.id, mutations: mutations_data }
    end

    before do
      allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
    end

    it "creates variant PromptVersions" do
      result = activity.execute(input)

      expect(result[:prompt_id]).to eq(prompt.id)
      expect(result[:variant_version_ids]).to be_an(Array)
      expect(result[:variant_count]).to eq(1)
    end

    it "persists versions via CreateVariants service" do
      expect {
        activity.execute(input)
      }.to change { prompt.prompt_versions.count }.by(1)
    end

    it "returns review_required flag" do
      result = activity.execute(input)
      expect(result[:review_required]).to be(false)
    end

    context "with project scope" do
      let(:project) { create(:project, quality_paused_at: 1.hour.ago) }
      let(:prompt) { create(:prompt, :for_account, :with_version, account: project.account) }
      let(:input) { { prompt_id: prompt.id, project_id: project.id, mutations: mutations_data } }

      it "auto-resumes the scoped project" do
        activity.execute(input)

        expect(project.reload).not_to be_quality_paused
      end
    end

    context "with review gate enabled" do
      let(:prompt) { create(:prompt, :global, :with_version, :requires_review) }

      it "reports review_required as true" do
        result = activity.execute(input)
        expect(result[:review_required]).to be(true)
      end
    end

    context "with empty mutations" do
      it "returns empty variant_version_ids" do
        result = activity.execute(prompt_id: prompt.id, mutations: [])

        expect(result[:variant_version_ids]).to be_empty
        expect(result[:variant_count]).to eq(0)
      end
    end

    context "when retried with identical input" do
      let(:mutations_data) do
        [
          { template: "Variant A {{title}}", strategy: "refinement", reasoning: "a", expected_improvement: "x" },
          { template: "Variant B {{title}}", strategy: "simplification", reasoning: "b", expected_improvement: "y" }
        ]
      end

      it "reuses the PromptVersions instead of duplicating them" do
        first = activity.execute(input)
        second = activity.execute(input)

        expect(second[:variant_version_ids]).to match_array(first[:variant_version_ids])
        expect { activity.execute(input) }.not_to change { prompt.prompt_versions.count }
        expect(prompt.prompt_versions.where.not(idempotency_key: nil).count).to eq(2)
      end
    end
  end
end
