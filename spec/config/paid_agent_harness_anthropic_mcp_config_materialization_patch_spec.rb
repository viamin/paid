# frozen_string_literal: true

require "rails_helper"

RSpec.describe PaidAgentHarnessAnthropicMcpConfigMaterializationPatch do
  # Minimal stub of the Anthropic provider that supplies the methods the patch
  # delegates to via super.
  let(:base_provider_class) do
    Class.new do
      attr_reader :last_options

      def send_message(prompt:, **options)
        @last_options = options
        :send_message_called
      end

      def plan_execution(prompt:, **options)
        @last_options = options
        :plan_execution_called
      end

      protected

      def build_command(prompt, options)
        # Mimic the real Anthropic provider: only adds --mcp-config when servers
        # are non-empty.
        cmd = [ "claude", "--print", "--output-format=json" ]
        if options[:mcp_servers]&.any?
          cmd += [ "--mcp-config=/tmp/upstream_mcp.json" ]
        end
        cmd << prompt
        cmd
      end

      def build_execution_preparation(_options)
        nil
      end

      def mcp_provider_key
        :anthropic
      end
    end
  end

  let(:patched_class) do
    Class.new(base_provider_class).tap do |klass|
      klass.prepend(described_class)
    end
  end

  let(:provider) { patched_class.new }

  describe "#send_message" do
    it "injects mcp_servers: [] when not provided" do
      provider.send_message(prompt: "hello")
      expect(provider.last_options).to include(mcp_servers: [])
    end

    it "does not overwrite mcp_servers when already provided" do
      server = AgentHarness::McpServer.new(name: "my_server", transport: "stdio", command: "npx")
      provider.send_message(prompt: "hello", mcp_servers: [ server ])
      expect(provider.last_options[:mcp_servers]).to eq([ server ])
    end
  end

  describe "#plan_execution" do
    it "injects mcp_servers: [] when not provided" do
      provider.plan_execution(prompt: "hello")
      expect(provider.last_options).to include(mcp_servers: [])
    end
  end

  describe "#build_command (protected)" do
    subject(:command) { provider.send(:build_command, "the prompt", options) }

    context "when mcp_servers is empty (suppression path)" do
      let(:options) { { mcp_servers: [] } }

      it "inserts --mcp-config=<path> before the prompt" do
        expect(command.last).to eq("the prompt")
        mcp_flag = command.find { |part| part.start_with?("--mcp-config=") }
        expect(mcp_flag).to be_present
      end

      it "does not duplicate --mcp-config when base already emits none" do
        mcp_flags = command.count { |part| part.start_with?("--mcp-config") }
        expect(mcp_flags).to eq(1)
      end

      it "generates an empty mcpServers config file content" do
        content = provider.send(:mcp_config_plan, options).fetch(:content)
        expect(JSON.parse(content)).to eq("mcpServers" => {})
      end
    end

    context "when mcp_servers is absent from options" do
      let(:options) { {} }

      it "does not add --mcp-config because materialize is not triggered" do
        mcp_flags = command.count { |part| part.start_with?("--mcp-config") }
        expect(mcp_flags).to eq(0)
      end
    end

    context "when base command already has --mcp-config= (non-empty servers path)" do
      let(:options) do
        {
          mcp_servers: [
            AgentHarness::McpServer.new(name: "myserver", transport: "stdio", command: "npx")
          ]
        }
      end

      it "replaces the upstream --mcp-config= with the planned path" do
        mcp_flags = command.select { |part| part.start_with?("--mcp-config=") }
        expect(mcp_flags.size).to eq(1)
        expect(mcp_flags.first).not_to eq("--mcp-config=/tmp/upstream_mcp.json")
      end

      it "keeps the prompt as the last argument" do
        expect(command.last).to eq("the prompt")
      end
    end
  end

  describe "#build_execution_preparation (protected)" do
    context "when mcp_servers is in options (materialization triggered)" do
      let(:options) { { mcp_servers: [] } }

      it "returns an ExecutionPreparation with a file write for the MCP config" do
        result = provider.send(:build_execution_preparation, options)
        expect(result).to be_a(AgentHarness::ExecutionPreparation)
        expect(result.file_writes.size).to eq(1)
        write = result.file_writes.first
        expect(write.path).to eq(provider.send(:mcp_config_plan, options).fetch(:path))
        expect(write.mode).to eq(0o600)
        expect(JSON.parse(write.content)).to eq("mcpServers" => {})
      end
    end

    context "when mcp_servers is absent from options" do
      let(:options) { {} }

      it "returns nil (no materialization needed)" do
        result = provider.send(:build_execution_preparation, options)
        expect(result).to be_nil
      end
    end

    context "when base returns an existing preparation" do
      let(:base_class_with_preparation) do
        Class.new(base_provider_class) do
          def build_execution_preparation(_options)
            AgentHarness::ExecutionPreparation.new(
              file_writes: [ { path: "/existing/file", content: "data", mode: 0o644 } ]
            )
          end
        end
      end

      let(:patched_with_base) do
        Class.new(base_class_with_preparation).tap do |klass|
          klass.prepend(described_class)
        end.new
      end

      it "merges MCP config write with the existing preparation" do
        result = patched_with_base.send(:build_execution_preparation, mcp_servers: [])
        expect(result.file_writes.size).to eq(2)
        paths = result.file_writes.map(&:path)
        expect(paths).to include("/existing/file")
        mcp_write = result.file_writes.find { |w| w.path != "/existing/file" }
        expect(JSON.parse(mcp_write.content)).to eq("mcpServers" => {})
      end
    end
  end
end
