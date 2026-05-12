# frozen_string_literal: true

require "rails_helper"

RSpec.describe RunnersHelper do
  describe "#runner_auth_instruction_blocks" do
    it "returns explicit copy for supported runners that define it" do
      allow(RunnerSupport).to receive(:supported_runner_keys).and_return(%w[claude codex])

      blocks = helper.runner_auth_instruction_blocks

      expect(blocks).to contain_exactly(
        hash_including(
          runner_key: "claude",
          title: Runner.display_name("claude"),
          fallback: false,
          summary: "Use one of these:"
        ),
        hash_including(
          runner_key: "codex",
          title: Runner.display_name("codex"),
          fallback: false,
          summary: "Use one of these:"
        )
      )
    end

    it "returns the generic checklist without logging for runners missing explicit copy" do
      allow(RunnerSupport).to receive(:supported_runner_keys).and_return(%w[mystery_runner])
      allow(Rails.logger).to receive(:warn)

      blocks = helper.runner_auth_instruction_blocks

      expect(blocks).to contain_exactly(
        hash_including(
          runner_key: "mystery_runner",
          title: Runner.display_name("mystery_runner"),
          fallback: true,
          summary: "Use the auth mode configured on the runner entry:"
        )
      )
      expect(Rails.logger).not_to have_received(:warn)
    end
  end
end
