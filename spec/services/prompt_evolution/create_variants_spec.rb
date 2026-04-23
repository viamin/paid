# frozen_string_literal: true

require "rails_helper"

RSpec.describe PromptEvolution::CreateVariants do
  let(:user) { create(:user) }
  let(:prompt) { create(:prompt, :global, :with_version) }
  let(:mutation) do
    PromptEvolution::Mutate::Mutation.new(
      template: "Refined template {{title}}",
      strategy: "refinement",
      reasoning: "Clearer instructions",
      expected_improvement: "Better results"
    )
  end

  describe ".call" do
    before do
      allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
    end

    context "when the prompt requires review" do
      before { prompt.update!(requires_review: true) }

      it "creates pending versions and does NOT promote them" do
        original_current = prompt.current_version

        variants = described_class.call(prompt: prompt, mutations: [ mutation ], created_by_user: user)

        expect(variants.size).to eq(1)
        expect(variants.first).to be_pending_review
        expect(prompt.reload.current_version).to eq(original_current)
      end

      it "stamps evolution provenance" do
        variants = described_class.call(prompt: prompt, mutations: [ mutation ], created_by_user: user)
        variant = variants.first

        expect(variant.created_by).to eq("evolution")
        expect(variant.created_by_user).to eq(user)
        expect(variant.parent_version).to eq(prompt.current_version)
        expect(variant.change_notes).to include("refinement")
      end
    end

    context "when the prompt does NOT require review" do
      it "auto-promotes the first variant and marks it approved" do
        original_current = prompt.current_version

        variants = described_class.call(prompt: prompt, mutations: [ mutation ], created_by_user: user)

        winner = variants.first.reload
        expect(winner).to be_approved
        expect(prompt.reload.current_version).to eq(winner)
        expect(prompt.current_version).not_to eq(original_current)
      end

      it "returns an empty array when no mutations are supplied" do
        expect(described_class.call(prompt: prompt, mutations: [])).to eq([])
      end
    end

    context "with a targeted project scope" do
      let(:project) { create(:project, quality_paused_at: 1.hour.ago) }
      let(:prompt) { create(:prompt, :for_account, :with_version, account: project.account) }

      it "auto-resumes the paused project after creating variants" do
        variants = described_class.call(prompt: prompt, mutations: [ mutation ], project: project)

        expect(variants).not_to be_empty
        expect(project.reload).not_to be_quality_paused
        expect(project.quality_pause_events.resumes.last.metadata).to include(
          "reason" => "prompt_evolution_variant_created",
          "prompt_id" => prompt.id,
          "variant_version_ids" => variants.map(&:id)
        )
      end
    end
  end
end
