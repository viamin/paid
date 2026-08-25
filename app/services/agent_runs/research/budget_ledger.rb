# frozen_string_literal: true

module AgentRuns
  module Research
    class BudgetLedger
      REQUEST_LIMIT = 3
      BYTE_LIMIT = 250_000
      TOKEN_LIMIT = 60_000
      METADATA_KEY = "research_usage"

      def self.reserve_request!(agent_run:)
        usage = nil

        agent_run.with_lock do
          usage = current_usage(agent_run)
          if usage["requests_used"] >= REQUEST_LIMIT
            raise BudgetExceededError
          end

          usage["requests_used"] += 1
          persist_usage!(agent_run, usage)
        end

        usage
      end

      def self.consume_response!(agent_run:, bytes:, tokens:)
        usage = nil

        agent_run.with_lock do
          usage = current_usage(agent_run)
          if usage["bytes_used"] + bytes > BYTE_LIMIT || usage["tokens_used"] + tokens > TOKEN_LIMIT
            raise BudgetExceededError
          end

          usage["bytes_used"] += bytes
          usage["tokens_used"] += tokens
          persist_usage!(agent_run, usage)
        end

        usage
      end

      def self.snapshot(agent_run)
        current_usage(agent_run)
      end

      def self.current_usage(agent_run)
        raw = agent_run.external_metadata.fetch(METADATA_KEY, {})
        normalized = raw.is_a?(Hash) ? raw.deep_stringify_keys : {}
        {
          "requests_used" => normalized.fetch("requests_used", 0).to_i,
          "bytes_used" => normalized.fetch("bytes_used", 0).to_i,
          "tokens_used" => normalized.fetch("tokens_used", 0).to_i
        }
      end

      def self.persist_usage!(agent_run, usage)
        metadata = agent_run.external_metadata.deep_dup
        metadata[METADATA_KEY] = usage
        agent_run.update!(external_metadata: metadata)
      end
      private_class_method :persist_usage!
    end
  end
end
