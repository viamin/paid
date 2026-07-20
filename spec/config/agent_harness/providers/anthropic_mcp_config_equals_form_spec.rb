# frozen_string_literal: true

require "rails_helper"

# Regression coverage that pins agent-harness >= 0.20.0 behavior on which
# RDR-007 removal of `PaidAgentHarnessAnthropicMcpConfigFlagFormPatch` depends:
#
# Before 0.20.1, Anthropic#build_mcp_flags returned the variadic
# `--mcp-config <path>` (two-token) form, which the Claude CLI greedily parsed
# as two configs, consuming the positional prompt as the second path. Paid
# carried `PaidAgentHarnessAnthropicMcpConfigFlagFormPatch` to convert the
# tokens back into the equals form. The upstream fix in 0.20.1 (commit
# 481d734) ships the equals form natively, so the local patch can be removed.
#
# If these expectations ever start failing, the upstream Anthropic provider
# has regressed and Paid must reinstate a local flag-form shim rather than
# silently produce broken `--mcp-config ... <prompt>` invocations.
RSpec.describe AgentHarness::Providers::Anthropic do
  subject(:anthropic_provider) { described_class.new }

  describe "#build_mcp_flags" do
    let(:server) do
      AgentHarness::McpServer.new(name: "myserver", transport: "stdio", command: "npx")
    end

    it "emits --mcp-config in equals form so the variadic flag cannot consume the positional prompt" do
      flags = anthropic_provider.send(:build_mcp_flags, [ server ])

      expect(flags.size).to eq(1)
      expect(flags.first).to start_with("--mcp-config=")
    end

    it "never emits the two-token space-separated form Paid used to patch" do
      flags = anthropic_provider.send(:build_mcp_flags, [ server ])

      mcp_tokens = flags.select { |flag| flag.to_s.start_with?("--mcp-config") }
      expect(mcp_tokens.size).to eq(1)
    end
  end
end
