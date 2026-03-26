# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Collectors::ConfigKeyCollector, :no_db do
  subject(:collector) do
    described_class.new(
      project: project,
      project_version: project_version,
      collector_run: collector_run,
      options: { scan_path: fixture_path }
    )
  end

  let(:project) { Struct.new(:id).new(1) }
  let(:project_version) { Struct.new(:id).new(1) }
  let(:collector_run) { Struct.new(:id).new(1) }
  let(:fixture_path) { Rails.root.join("spec/fixtures/knowledge").to_s }

  describe "#collector_type" do
    it "returns config_key" do
      expect(collector.collector_type).to eq("config_key")
    end
  end

  describe "#tool_version" do
    it "returns the ast-grep version string" do
      expect(collector.tool_version).to match(/ast-grep \d+\.\d+\.\d+/)
    end
  end

  describe "#collect" do
    let(:artifacts) { collector.collect }

    it "extracts ENV[] references" do
      keys = artifacts.map { |a| a[:identifier] }

      expect(keys).to include("DATABASE_URL", "API_KEY")
    end

    it "extracts ENV.fetch() references" do
      keys = artifacts.map { |a| a[:identifier] }

      expect(keys).to include("REDIS_URL", "OPTIONAL_KEY")
    end

    it "sets artifact_type to config_key" do
      expect(artifacts).to all(include(artifact_type: "config_key"))
    end

    it "includes file path and line in metadata" do
      db_url = artifacts.find { |a| a[:identifier] == "DATABASE_URL" }

      expect(db_url[:metadata][:file_path]).to match(/config_sample\.rb/)
      expect(db_url[:metadata][:line]).to be_a(Integer)
    end

    it "includes an evidence chunk for each artifact" do
      artifacts.each do |artifact|
        expect(artifact[:chunks].length).to eq(1)
        expect(artifact[:chunks].first[:chunk_type]).to eq("evidence")
      end
    end

    it "deduplicates by key and scope_path" do
      identifiers_with_scope = artifacts.map { |a| [ a[:identifier], a[:scope_path] ] }

      expect(identifiers_with_scope).to eq(identifiers_with_scope.uniq)
    end

    it "produces idempotent results" do
      first_run = collector.collect
      second_run = collector.collect

      expect(first_run).to eq(second_run)
    end

    context "when ast-grep returns no results" do
      before do
        allow(Open3).to receive(:capture3).and_return(
          [ "[]", "", instance_double(Process::Status, success?: true, exitstatus: 0) ]
        )
      end

      it "returns an empty array" do
        expect(collector.collect).to eq([])
      end
    end

    context "when ast-grep is not installed" do
      before do
        allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)
      end

      it "returns an empty array" do
        expect(collector.collect).to eq([])
      end
    end
  end
end
