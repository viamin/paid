# frozen_string_literal: true

require "rails_helper"

# @spec TDD-GUARD-003
# @spec TDD-GUARD-004
# @spec TDD-GUARD-005
RSpec.describe Tdd::WriteGuard do
  let(:agent_run) { build_stubbed(:agent_run, tdd_phase: tdd_phase, tdd_returned_to_test_review: returned_to_test_review) }
  let(:returned_to_test_review) { false }

  describe ".call" do
    context "when the run is not TDD-governed" do
      let(:tdd_phase) { nil }

      it "is always valid regardless of changed files" do
        result = described_class.call(agent_run: agent_run, changed_files: [ "spec/models/widget_spec.rb", "app/models/widget.rb" ])

        expect(result).to be_valid
        expect(result.forbidden_files).to eq([])
      end
    end

    context "when in test_writing phase" do
      let(:tdd_phase) { "test_writing" }

      it "allows test file changes" do
        result = described_class.call(agent_run: agent_run, changed_files: [ "spec/models/widget_spec.rb" ])

        expect(result).to be_valid
      end

      it "allows LID doc changes" do
        result = described_class.call(agent_run: agent_run, changed_files: [
          "docs/intent/widget/widget-specs.md", "AGENTS.md", "CLAUDE.md", ".github/copilot-instructions.md"
        ])

        expect(result).to be_valid
      end

      it "rejects implementation file changes" do
        result = described_class.call(agent_run: agent_run, changed_files: [ "spec/models/widget_spec.rb", "app/models/widget.rb" ])

        expect(result).not_to be_valid
        expect(result.forbidden_files).to eq([ "app/models/widget.rb" ])
        expect(result.reason).to eq("test-writing runs may not change implementation code")
        expect(result.phase).to eq("test_writing")
      end
    end

    context "when in test_fixing phase" do
      let(:tdd_phase) { "test_fixing" }

      it "allows implementation file changes" do
        result = described_class.call(agent_run: agent_run, changed_files: [ "app/models/widget.rb" ])

        expect(result).to be_valid
      end

      it "rejects test file changes when the run has not returned to test review" do
        result = described_class.call(agent_run: agent_run, changed_files: [ "app/models/widget.rb", "spec/models/widget_spec.rb" ])

        expect(result).not_to be_valid
        expect(result.forbidden_files).to eq([ "spec/models/widget_spec.rb" ])
        expect(result.reason).to eq("test-fixing runs may not change tests without returning the PR to test review")
      end

      context "when the run has returned the PR to test review" do
        let(:returned_to_test_review) { true }

        it "allows test file changes" do
          result = described_class.call(agent_run: agent_run, changed_files: [ "app/models/widget.rb", "spec/models/widget_spec.rb" ])

          expect(result).to be_valid
        end
      end
    end

    context "when in refactor phase" do
      let(:tdd_phase) { "refactor" }

      it "allows implementation file changes" do
        result = described_class.call(agent_run: agent_run, changed_files: [ "app/models/widget.rb" ])

        expect(result).to be_valid
      end

      it "rejects test file changes with no exception" do
        result = described_class.call(agent_run: agent_run, changed_files: [ "app/models/widget.rb", "test/models/widget_test.rb" ])

        expect(result).not_to be_valid
        expect(result.forbidden_files).to eq([ "test/models/widget_test.rb" ])
        expect(result.reason).to eq("refactor runs may not change tests")
      end

      context "when a refactor run has nonetheless returned to test review" do
        let(:returned_to_test_review) { true }

        it "still rejects test file changes" do
          result = described_class.call(agent_run: agent_run, changed_files: [ ".ephemeral-tests/widget_spec.rb" ])

          expect(result).not_to be_valid
          expect(result.forbidden_files).to eq([ ".ephemeral-tests/widget_spec.rb" ])
        end
      end
    end
  end
end
