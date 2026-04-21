# frozen_string_literal: true

module AgentHarness
  module Providers
    class Codex
      class << self
        # Expose the Codex CLI JSONL transcript parser for callers that capture
        # raw CLI stdout outside AgentHarness::Response parsing.
        def parse_cli_jsonl_transcript(raw_output)
          parsed = new.send(:parse_jsonl_output, raw_output)
          return parsed if parsed && parsed[:text].present?

          fallback_text = extract_turn_last_agent_message(raw_output)
          return parsed unless fallback_text

          {
            text: fallback_text,
            tokens: parsed&.dig(:tokens)
          }
        end

        private

        def extract_turn_last_agent_message(raw_output)
          raw_output.each_line.reverse_each do |line|
            event = parse_jsonl_event(line)
            next unless event
            next unless event["type"] == "turn.completed"

            text = extract_last_agent_message_text(event["last_agent_message"])
            return text if text.present?
          end

          nil
        end

        def parse_jsonl_event(line)
          JSON.parse(line)
        rescue JSON::ParserError
          nil
        end

        def extract_last_agent_message_text(last_agent_message)
          return last_agent_message if last_agent_message.is_a?(String) && last_agent_message.present?
          return nil unless last_agent_message.is_a?(Hash)

          new.send(:extract_task_complete_parts, "last_agent_message" => last_agent_message)&.join
        end
      end
    end
  end
end
