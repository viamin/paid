# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::GenerateMutationsActivity do
  let(:activity) { described_class.new }

  describe "class" do
    it "inherits from BaseActivity" do
      expect(described_class.superclass).to eq(Activities::BaseActivity)
    end
  end

  describe "#execute" do
    let(:prompt) { create(:prompt, :global, :with_version) }

    let(:input) do
      {
        prompt_id: prompt.id,
        mutation_count: 2,
        quality_metrics: [ { composite_score: 0.5 } ],
        sample_outputs: { successes: [ "good output" ], failures: [ "bad output" ] }
      }
    end

    context "when mutations are generated" do
      let(:mutations) do
        [
          PromptEvolution::Mutate::Mutation.new(
            template: "improved {{title}}",
            strategy: "refinement",
            reasoning: "better structure",
            expected_improvement: "clarity"
          )
        ]
      end

      before do
        allow(PromptEvolution::Mutate).to receive(:call).and_return(mutations)
      end

      it "returns serialized mutations" do
        result = activity.execute(input)

        expect(result[:prompt_id]).to eq(prompt.id)
        expect(result[:mutations]).to be_an(Array)
        expect(result[:mutations].first).to include(
          template: "improved {{title}}",
          strategy: "refinement",
          reasoning: "better structure",
          expected_improvement: "clarity"
        )
      end

      it "passes quality metrics and sample outputs to Mutate" do
        activity.execute(input)

        expect(PromptEvolution::Mutate).to have_received(:call).with(
          prompt: prompt,
          quality_metrics: array_including(
            have_attributes(composite_score: 0.5)
          ),
          sample_outputs: hash_including(successes: [ "good output" ]),
          options: hash_including(mutation_count: 2)
        )
      end
    end

    context "when no mutations are generated" do
      before do
        allow(PromptEvolution::Mutate).to receive(:call).and_return([])
      end

      it "returns empty mutations array" do
        result = activity.execute(input)

        expect(result[:mutations]).to be_empty
      end
    end

    context "with invalid prompt_id" do
      it "raises ActiveRecord::RecordNotFound" do
        expect {
          activity.execute(input.merge(prompt_id: -1))
        }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end
end
