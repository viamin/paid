# frozen_string_literal: true

require "rails_helper"

RSpec.describe AbTests::PromoteWinner do
  let(:project) { create(:project) }
  let(:prompt) { create(:prompt, :with_version, project: project, account: project.account) }
  let(:original_version) { prompt.current_version }
  let(:new_version) do
    next_version = (prompt.prompt_versions.maximum(:version) || 0) + 1
    create(:prompt_version, prompt: prompt, version: next_version, template: "Better template {{title}}")
  end
  let(:ab_test) { create(:ab_test, prompt: prompt, status: "completed", started_at: 1.day.ago, completed_at: Time.current) }
  let(:winner_variant) { create(:ab_test_variant, ab_test: ab_test, prompt_version: new_version) }

  before do
    ab_test.update!(winner_variant: winner_variant)
  end

  describe ".call" do
    it "promotes the winning version as the prompt's current version" do
      # Verify current_version is NOT new_version before promotion
      expect(prompt.reload.current_version).to eq(original_version)

      described_class.call(ab_test: ab_test)

      expect(prompt.reload.current_version).to eq(new_version)
    end

    it "marks the recovery action executed only after the winning version is promoted" do
      action = create(:quality_recovery_action, :prompt_evolution, :executing,
        project: prompt.project,
        prompt_version: original_version,
        executed_at: nil,
        result: {
          ab_test_id: ab_test.id,
          status: "winner_found",
          winner_prompt_version_id: new_version.id
        })

      described_class.call(ab_test: ab_test)

      expect(action.reload.status).to eq("executed")
      expect(action.executed_at).to be_present
    end

    it "raises when test is not completed" do
      ab_test.update_column(:status, "running")

      expect { described_class.call(ab_test: ab_test) }.to raise_error(ArgumentError, /not completed/)
    end

    it "raises when there is no winner" do
      ab_test.update!(winner_variant: nil)

      expect { described_class.call(ab_test: ab_test) }.to raise_error(ArgumentError, /no winner/)
    end

    context "when the prompt requires human review" do
      before { prompt.update!(requires_review: true) }

      it "does NOT promote immediately; marks the winning version pending" do
        original = prompt.current_version
        action = create(:quality_recovery_action, :prompt_evolution, :executing,
          project: prompt.project,
          prompt_version: original_version,
          executed_at: nil,
          result: {
            ab_test_id: ab_test.id,
            status: "winner_found",
            winner_prompt_version_id: new_version.id
          })

        described_class.call(ab_test: ab_test)

        expect(prompt.reload.current_version).to eq(original)
        expect(new_version.reload).to be_pending_review
        expect(action.reload.status).to eq("executing")
        expect(action.executed_at).to be_nil
      end

      it "leaves an already-approved winner alone" do
        new_version.update!(review_status: "approved")

        described_class.call(ab_test: ab_test)

        # current_version still not auto-promoted (requires explicit approval
        # through PromptReviews::Approve), and status preserved.
        expect(new_version.reload).to be_approved
      end

      it "returns the winning version regardless of gate" do
        expect(described_class.call(ab_test: ab_test)).to eq(new_version)
      end
    end
  end
end
