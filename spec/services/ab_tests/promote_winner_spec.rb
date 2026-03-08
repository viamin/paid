# frozen_string_literal: true

require "rails_helper"

RSpec.describe AbTests::PromoteWinner do
  let(:prompt) { create(:prompt, :global, :with_version) }
  let(:original_version) { prompt.current_version }
  let(:new_version) { prompt.create_version!(template: "Better template {{title}}") }
  let(:ab_test) { create(:ab_test, prompt: prompt, status: "completed", started_at: 1.day.ago, completed_at: Time.current) }
  let(:winner_variant) { create(:ab_test_variant, ab_test: ab_test, prompt_version: new_version) }

  before do
    ab_test.update!(winner_variant: winner_variant)
  end

  describe ".call" do
    it "promotes the winning version as the prompt's current version" do
      described_class.call(ab_test: ab_test)

      expect(prompt.reload.current_version).to eq(new_version)
    end

    it "raises when test is not completed" do
      ab_test.update_column(:status, "running")

      expect { described_class.call(ab_test: ab_test) }.to raise_error(ArgumentError, /not completed/)
    end

    it "raises when there is no winner" do
      ab_test.update!(winner_variant: nil)

      expect { described_class.call(ab_test: ab_test) }.to raise_error(ArgumentError, /no winner/)
    end
  end
end
