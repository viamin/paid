# frozen_string_literal: true

require "rails_helper"

# Regression coverage that pins agent-harness >= 0.36.8 behavior, adopted for
# the 2026-08-24 issue-analysis provider outage (#3643,
# viamin/agent-harness#367).
#
# Before 0.36.8, the Claude CLI's JSON envelope for a missing/expired local
# session —
#   {"type":"result","subtype":"success","is_error":true,
#    "result":"Not logged in · Please run /login","exit_code":1}
# — was returned as a generic unsuccessful Response instead of a structured
# authentication failure: `classify_error_message` only recognized
# "oauth token" / "authentication" substrings, so "Not logged in" fell
# through to a generic error string. Paid's own provider-fallback loop
# (`Activities::AnalyzeIssueActivity#call_llm`, ISSUE-ANALYSIS-009) already
# rescues `AgentHarness::AuthenticationError` and opens that provider's
# circuit breaker immediately, but it only ever received the generic
# `AgentHarness::Error` path for this case — so a deterministically
# unauthenticated Claude kept eating the owner's generic failure-threshold
# budget instead of being cut off immediately, and downstream callers only
# ever saw generic provider exhaustion.
#
# agent-harness 0.36.8 fixes this at the source: the Claude provider now
# trusts `is_error` and the process exit code over the envelope's
# `subtype: "success"`, recognizes "not logged in" (among other login/session
# phrases), and raises `AgentHarness::AuthenticationError` directly from
# `parse_response` rather than returning it as response error text.
#
# If this spec ever starts failing, the upstream Anthropic provider has
# regressed and Paid's issue-analysis fallback will silently stop
# distinguishing expired Claude credentials from generic provider failures.
RSpec.describe AgentHarness::Providers::Anthropic do
  subject(:claude_provider) { AgentHarness.provider(:claude) }

  # The exact envelope observed in production (viamin/agent-harness#367).
  let(:not_logged_in_envelope) do
    {
      type: "result",
      subtype: "success",
      is_error: true,
      result: "Not logged in · Please run /login",
      exit_code: 1
    }.to_json
  end

  let(:cli_result) do
    AgentHarness::CommandExecutor::Result.new(not_logged_in_envelope, "", 1, 0.1)
  end

  it "raises AuthenticationError instead of trusting the envelope's subtype: success" do
    expect {
      claude_provider.send(:parse_response, cli_result, duration: 0.1)
    }.to raise_error(AgentHarness::AuthenticationError, /Not logged in/)
  end

  it "still classifies as an authentication failure via the generic taxonomy if ever surfaced as response text" do
    # parse_response now raises AuthenticationError directly for this
    # envelope (the primary path, covered above), so
    # Activities::AnalyzeIssueActivity's response-shaped fallback
    # (#classify_response_error -> AgentHarness::ErrorTaxonomy.classify_message,
    # ISSUE-ANALYSIS-007/009) never sees it for Claude specifically. This pins
    # the belt-and-suspenders case: the friendly message the provider's own
    # #classify_error_message normalizes "not logged in" text to still
    # classifies as :auth_expired under Paid's generic (non-provider-specific)
    # taxonomy lookup, so any other code path that surfaces it as response
    # text (rather than a raised error) is still routed correctly.
    classification = AgentHarness::ErrorTaxonomy.classify_message("Authentication error")

    expect(classification).to eq(:auth_expired)
  end
end
