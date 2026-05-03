# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::StreamingEventProcessor do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project: project) }
  let(:logged_events) { [] }
  let(:logger) { ->(message, **metadata) { logged_events << { message: message, **metadata } } }
  let(:processor) { described_class.new(agent_run: agent_run, logger: logger) }

  describe "#parse_line" do
    it "returns nil for blank lines" do
      expect(processor.parse_line("")).to be_nil
      expect(processor.parse_line(nil)).to be_nil
      expect(processor.parse_line("   ")).to be_nil
    end

    it "returns nil for non-JSON lines" do
      expect(processor.parse_line("plain text output")).to be_nil
    end

    it "returns nil for brace-free lines without invoking the JSON parser" do
      expect(processor).not_to receive(:parse_jsonl_event)

      expect(processor.parse_line("progress: still working")).to be_nil
    end

    it "returns nil for JSON without type field" do
      expect(processor.parse_line('{"key": "value"}')).to be_nil
    end

    it "parses progress events" do
      line = '{"type": "progress", "message": "working"}'
      result = processor.parse_line(line)

      expect(result[:type]).to eq(:progress)
      expect(result[:raw_type]).to eq("progress")
      expect(result[:event]["type"]).to eq("progress")
    end

    it "parses token_usage events" do
      line = '{"type": "token_usage", "usage": {"input_tokens": 100, "output_tokens": 50}}'
      result = processor.parse_line(line)

      expect(result[:type]).to eq(:progress)
    end

    it "parses turn_complete events" do
      line = '{"type": "turn_complete", "usage": {"input_tokens": 500, "output_tokens": 200}}'
      result = processor.parse_line(line)

      expect(result[:type]).to eq(:turn_complete)
    end

    it "parses turn.complete events" do
      line = '{"type": "turn.complete", "usage": {"input_tokens": 500, "output_tokens": 200}}'
      result = processor.parse_line(line)

      expect(result[:type]).to eq(:turn_complete)
    end

    it "parses turn.failed events" do
      line = '{"type": "turn.failed", "message": "context window exceeded"}'
      result = processor.parse_line(line)

      expect(result[:type]).to eq(:turn_failed)
    end

    it "parses error events" do
      line = '{"type": "error", "message": "API error"}'
      result = processor.parse_line(line)

      expect(result[:type]).to eq(:error)
    end

    it "returns nil for unknown event types" do
      line = '{"type": "unknown_custom_type", "data": "something"}'
      result = processor.parse_line(line)

      expect(result[:type]).to be_nil
    end
  end

  describe "#process" do
    it "returns :activity for progress events" do
      parsed = { type: :progress, event: { "type" => "progress" }, raw_type: "progress" }
      expect(processor.process(parsed)).to eq(:activity)
    end

    it "returns :activity for turn_complete events and increments turn count" do
      parsed = {
        type: :turn_complete,
        event: { "type" => "turn_complete", "usage" => { "input_tokens" => 500, "output_tokens" => 200 } },
        raw_type: "turn_complete"
      }

      expect(processor.process(parsed)).to eq(:activity)
      expect(processor.turns_completed).to eq(1)
    end

    it "returns :abort for turn_failed events" do
      parsed = {
        type: :turn_failed,
        event: { "type" => "turn.failed", "message" => "context window exceeded" },
        raw_type: "turn.failed"
      }

      expect(processor.process(parsed)).to eq(:abort)
      expect(processor.turns_completed).to eq(1)
    end

    it "returns :abort for error events" do
      parsed = {
        type: :error,
        event: { "type" => "error", "message" => "fatal error" },
        raw_type: "error"
      }

      expect(processor.process(parsed)).to eq(:abort)
    end

    it "returns nil for unknown events" do
      expect(processor.process(nil)).to be_nil
    end

    it "tracks last_event_type from the raw event" do
      parsed = {
        type: :error,
        event: { "type" => "error", "message" => "fatal" },
        raw_type: "error"
      }

      processor.process(parsed)
      expect(processor.last_event_type).to eq("error")
    end
  end

  describe "#handle_line" do
    it "parses and processes a progress event in one call" do
      line = '{"type": "progress", "message": "working"}'
      expect(processor.handle_line(line)).to eq(:activity)
    end

    it "parses and processes a turn.failed event in one call" do
      line = '{"type": "turn.failed", "message": "context window exceeded"}'
      expect(processor.handle_line(line)).to eq(:abort)
    end

    it "returns nil for non-event lines" do
      expect(processor.handle_line("regular output")).to be_nil
    end
  end

  describe "#flush_metrics!" do
    it "persists turn metrics to the agent_run" do
      # Simulate two turn completions
      processor.handle_line('{"type": "turn_complete", "usage": {"input_tokens": 500, "output_tokens": 200}}')
      processor.handle_line('{"type": "turn_complete", "usage": {"input_tokens": 300, "output_tokens": 100}}')

      processor.flush_metrics!

      agent_run.reload
      expect(agent_run.turns_completed).to eq(2)
      expect(agent_run.streaming_turns_data.length).to eq(2)
      expect(agent_run.streaming_turns_data.first["turn_number"]).to eq(1)
      expect(agent_run.streaming_turns_data.first["input_tokens"]).to eq(500)
      expect(agent_run.streaming_turns_data.first["output_tokens"]).to eq(200)
      expect(agent_run.streaming_turns_data.second["turn_number"]).to eq(2)
    end

    it "records failed turns with error details" do
      processor.handle_line('{"type": "turn.failed", "message": "context window exceeded"}')

      processor.flush_metrics!

      agent_run.reload
      expect(agent_run.turns_completed).to eq(1)
      expect(agent_run.streaming_turns_data.first["status"]).to eq("failed")
      expect(agent_run.streaming_turns_data.first["error"]).to include("context window exceeded")
    end

    it "merges with previously persisted metrics instead of overwriting" do
      # Simulate a first exec that already persisted metrics
      agent_run.update_columns(
        turns_completed: 3,
        streaming_turns_data: [
          { "turn_number" => 1, "input_tokens" => 100 },
          { "turn_number" => 2, "input_tokens" => 200 },
          { "turn_number" => 3, "input_tokens" => 300 }
        ]
      )

      # Second exec records one more turn
      processor.handle_line('{"type": "turn_complete", "usage": {"input_tokens": 400, "output_tokens": 50}}')
      processor.flush_metrics!

      agent_run.reload
      expect(agent_run.turns_completed).to eq(4)
      expect(agent_run.streaming_turns_data.length).to eq(4)
      expect(agent_run.streaming_turns_data.last["turn_number"]).to eq(4)
      expect(agent_run.streaming_turns_data.last["input_tokens"]).to eq(400)
    end

    it "skips update when no events were processed" do
      expect(agent_run).not_to receive(:update_columns)
      processor.flush_metrics!
    end
  end

  describe "structured logging" do
    it "logs progress events with turn context" do
      processor.handle_line('{"type": "progress", "usage": {"input_tokens": 100, "output_tokens": 50}}')

      expect(logged_events.last[:message]).to eq("container.execute.progress")
      expect(logged_events.last[:tokens_input]).to eq(100)
      expect(logged_events.last[:tokens_output]).to eq(50)
    end

    it "logs turn_complete events with metrics" do
      processor.handle_line('{"type": "turn_complete", "usage": {"input_tokens": 500, "output_tokens": 200}, "duration_ms": 5000}')

      expect(logged_events.last[:message]).to eq("container.execute.turn_complete")
      expect(logged_events.last[:turn_number]).to eq(1)
      expect(logged_events.last[:input_tokens]).to eq(500)
      expect(logged_events.last[:output_tokens]).to eq(200)
      expect(logged_events.last[:duration_ms]).to eq(5000)
    end

    it "logs turn_failed events with error message" do
      processor.handle_line('{"type": "turn.failed", "message": "context window exceeded"}')

      expect(logged_events.last[:message]).to eq("container.execute.turn_failed")
      expect(logged_events.last[:error]).to include("context window exceeded")
    end

    it "logs error events" do
      processor.handle_line('{"type": "error", "message": "API error"}')

      expect(logged_events.last[:message]).to eq("container.execute.streaming_error")
      expect(logged_events.last[:error]).to eq("API error")
    end
  end

  describe "agent-harness fallback" do
    it "uses fallback JSON parsing when agent-harness method is not available" do
      # The fallback parser should work for standard JSONL
      line = '{"type": "progress", "message": "working"}'
      result = processor.parse_line(line)

      expect(result).not_to be_nil
      expect(result[:type]).to eq(:progress)
    end
  end
end
