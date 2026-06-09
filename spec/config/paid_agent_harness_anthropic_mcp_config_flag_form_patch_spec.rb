# frozen_string_literal: true

require "rails_helper"

RSpec.describe PaidAgentHarnessAnthropicMcpConfigFlagFormPatch do
  let(:base_class) do
    Class.new do
      protected

      def build_mcp_flags(mcp_servers, working_dir: nil)
        return [] if mcp_servers.empty?

        [ "--mcp-config", "/tmp/mcp_config.json" ]
      end
    end
  end

  let(:patched_class) do
    Class.new(base_class).tap do |klass|
      klass.prepend(described_class)
    end
  end

  let(:provider) { patched_class.new }

  describe "#build_mcp_flags (protected)" do
    context "when upstream returns space-separated form" do
      let(:server) { AgentHarness::McpServer.new(name: "myserver", transport: "stdio", command: "npx") }

      it "converts to equals form" do
        flags = provider.send(:build_mcp_flags, [ server ])
        expect(flags).to eq([ "--mcp-config=/tmp/mcp_config.json" ])
      end
    end

    context "when servers are empty" do
      it "returns empty array unchanged" do
        flags = provider.send(:build_mcp_flags, [])
        expect(flags).to eq([])
      end
    end

    context "when upstream already returns equals form" do
      let(:base_class_equals_form) do
        Class.new do
          protected

          def build_mcp_flags(mcp_servers, working_dir: nil)
            return [] if mcp_servers.empty?

            [ "--mcp-config=/tmp/already_equals.json" ]
          end
        end
      end

      let(:patched_equals) do
        Class.new(base_class_equals_form).tap do |klass|
          klass.prepend(described_class)
        end.new
      end

      it "returns unchanged (self-deactivates)" do
        server = AgentHarness::McpServer.new(name: "myserver", transport: "stdio", command: "npx")
        flags = patched_equals.send(:build_mcp_flags, [ server ])
        expect(flags).to eq([ "--mcp-config=/tmp/already_equals.json" ])
      end
    end
  end
end
