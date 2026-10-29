# frozen_string_literal: true

module PartialCloseouts
  # Retrieves submitted evidence through the bounded, SSRF-safe research
  # transport and converts markup to plain text before LLM assessment.
  # @spec PARTIAL-CLOSEOUT-035
  class FetchEvidenceArtifact
    MAX_PROMPT_CHARS = 12_000

    def self.call(url)
      response = AgentRuns::Research::HttpClient.fetch(url:, method: "GET")
      body = sanitize(response).truncate(MAX_PROMPT_CHARS)
      raise AgentRuns::Research::RequestInvalidError, "Evidence artifact was blank" if body.strip.blank?

      body
    end

    def self.sanitize(response)
      body = response.body.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "").scrub
      return body unless response.content_type == "text/html"

      Nokogiri::HTML5.fragment(body).tap { |fragment| fragment.css("script, style").remove }.text
    end
    private_class_method :sanitize
  end
end
