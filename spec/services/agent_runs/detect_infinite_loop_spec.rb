# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::DetectInfiniteLoop do
  describe ".call" do
    let(:agent_run) { create(:agent_run, :running) }

    context "when there are fewer outputs than the window size" do
      before do
        3.times { create(:agent_run_log, agent_run: agent_run, log_type: "stdout", content: "same output repeated here") }
      end

      it "does not detect a loop" do
        result = described_class.call(agent_run: agent_run)

        expect(result.loop_detected?).to be false
        expect(result.no_loop?).to be true
      end
    end

    context "when outputs are all different" do
      before do
        10.times do |i|
          create(:agent_run_log, agent_run: agent_run, log_type: "stdout", content: "unique output number #{i} with enough length")
        end
      end

      it "does not detect a loop" do
        result = described_class.call(agent_run: agent_run)

        expect(result.loop_detected?).to be false
      end
    end

    context "when consecutive outputs are identical" do
      before do
        5.times do
          create(:agent_run_log, agent_run: agent_run, log_type: "stdout", content: "I'm stuck in a loop, retrying the same thing")
        end
      end

      it "detects a repeated output loop" do
        result = described_class.call(agent_run: agent_run)

        expect(result.loop_detected?).to be true
        expect(result.reason).to include("Repeated output detected")
        expect(result.reason).to include("5 consecutive identical outputs")
      end
    end

    context "when outputs differ only by whitespace" do
      before do
        5.times do |i|
          content = i.even? ? "retrying the same action here" : "retrying  the  same  action  here"
          create(:agent_run_log, agent_run: agent_run, log_type: "stdout", content: content)
        end
      end

      it "detects a loop (whitespace normalized)" do
        result = described_class.call(agent_run: agent_run)

        expect(result.loop_detected?).to be true
      end
    end

    context "when outputs cycle between two patterns" do
      before do
        10.times do |i|
          content = i.even? ? "Running lint check on the codebase" : "Error: lint check failed, retrying"
          create(:agent_run_log, agent_run: agent_run, log_type: "stdout", content: content)
        end
      end

      it "detects a low output variety pattern" do
        result = described_class.call(agent_run: agent_run)

        expect(result.loop_detected?).to be true
        expect(result.reason).to include("Low output variety detected")
        expect(result.reason).to include("2 unique outputs")
      end
    end

    context "when there are no stdout logs" do
      before do
        5.times { create(:agent_run_log, agent_run: agent_run, log_type: "system", content: "system heartbeat event log") }
      end

      it "does not detect a loop" do
        result = described_class.call(agent_run: agent_run)

        expect(result.loop_detected?).to be false
      end
    end

    context "when outputs are too short to be meaningful" do
      before do
        5.times { create(:agent_run_log, agent_run: agent_run, log_type: "stdout", content: "ok") }
      end

      it "ignores short outputs and does not detect a loop" do
        result = described_class.call(agent_run: agent_run)

        expect(result.loop_detected?).to be false
      end
    end

    context "with a custom window size" do
      before do
        3.times do
          create(:agent_run_log, agent_run: agent_run, log_type: "stdout", content: "repeating output content here")
        end
      end

      it "uses the custom window size for detection" do
        result = described_class.call(agent_run: agent_run, window_size: 3)

        expect(result.loop_detected?).to be true
      end
    end

    context "when identical outputs are not consecutive" do
      before do
        create(:agent_run_log, agent_run: agent_run, log_type: "stdout", content: "repeated content output here")
        create(:agent_run_log, agent_run: agent_run, log_type: "stdout", content: "repeated content output here")
        create(:agent_run_log, agent_run: agent_run, log_type: "stdout", content: "something completely different here")
        create(:agent_run_log, agent_run: agent_run, log_type: "stdout", content: "repeated content output here")
        create(:agent_run_log, agent_run: agent_run, log_type: "stdout", content: "repeated content output here")
      end

      it "does not detect a repeated output loop" do
        result = described_class.call(agent_run: agent_run)

        expect(result.loop_detected?).to be false
      end
    end

    context "when the agent run has no logs" do
      it "does not detect a loop" do
        result = described_class.call(agent_run: agent_run)

        expect(result.loop_detected?).to be false
      end
    end

    context "with invalid window_size" do
      it "raises ArgumentError for zero" do
        expect { described_class.call(agent_run: agent_run, window_size: 0) }
          .to raise_error(ArgumentError, "window_size must be a positive integer")
      end

      it "raises ArgumentError for negative values" do
        expect { described_class.call(agent_run: agent_run, window_size: -1) }
          .to raise_error(ArgumentError, "window_size must be a positive integer")
      end
    end
  end
end
