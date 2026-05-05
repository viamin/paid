# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::EmbeddingRunner, :no_db do
  let(:project) { Struct.new(:id).new(42) }
  let(:knowledge_run) do
    Struct.new(:id) do
      def ensure_proxy_token!
        "proxy-token"
      end
    end.new(7)
  end

  describe "#container_config" do
    it "bind-mounts the input directory read-only" do
      runner = described_class.new(project: project, knowledge_run: knowledge_run)
      runner.instance_variable_set(:@input_dir, "/tmp/paid-embedding-runner-test")

      config = runner.send(:container_config)

      expect(config.dig("HostConfig", "Binds")).to eq(
        [ "/tmp/paid-embedding-runner-test:/paid-input:ro" ]
      )
    end
  end
end
