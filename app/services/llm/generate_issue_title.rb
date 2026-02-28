# frozen_string_literal: true

module Llm
  # Generates a concise GitHub issue title from agent output using Anthropic's
  # Haiku model. Falls back to a truncated summary on API errors so that
  # issue creation is never blocked by LLM availability.
  #
  # @example
  #   title = Llm::GenerateIssueTitle.call(summary: "# Auth Analysis\n\nThe auth system...")
  #   # => "Authentication system security review"
  class GenerateIssueTitle
    API_URL = "https://api.anthropic.com/v1/messages"
    MODEL = "claude-haiku-4-5-20251001"
    MAX_TITLE_LENGTH = 255
    MAX_SUMMARY_INPUT = 4000

    SYSTEM_PROMPT = <<~PROMPT.strip
      You generate concise GitHub issue titles. Respond with ONLY the title text — no quotes, no prefix, no explanation. Keep it under 80 characters.
    PROMPT

    class << self
      def call(summary:)
        new(summary: summary).generate
      end
    end

    def initialize(summary:)
      @summary = summary
    end

    def generate
      return nil if @summary.blank?

      title = request_title
      title.present? ? title.truncate(MAX_TITLE_LENGTH) : nil
    rescue Faraday::Error, JSON::ParserError, KeyError => e
      Rails.logger.warn(
        message: "llm.generate_issue_title_failed",
        error_class: e.class.name,
        error: e.message
      )
      nil
    end

    private

    def request_title
      api_key = ENV["ANTHROPIC_API_KEY"]
      return nil if api_key.blank?

      response = connection.post(API_URL) do |req|
        req.headers["x-api-key"] = api_key
        req.headers["anthropic-version"] = "2023-06-01"
        req.body = {
          model: MODEL,
          max_tokens: 100,
          system: SYSTEM_PROMPT,
          messages: [
            { role: "user", content: user_prompt }
          ]
        }
      end

      extract_text(response.body)
    end

    def user_prompt
      truncated = @summary.truncate(MAX_SUMMARY_INPUT)
      "Generate a concise GitHub issue title for the following agent output:\n\n#{truncated}"
    end

    def extract_text(body)
      text = body.dig("content", 0, "text")
      text&.strip&.delete_prefix('"')&.delete_suffix('"')&.strip
    end

    def connection
      @connection ||= Faraday.new do |f|
        f.request :json
        f.response :json
        f.response :raise_error
        f.options.timeout = 15
        f.options.open_timeout = 5
        f.adapter Faraday.default_adapter
      end
    end
  end
end
