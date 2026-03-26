# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Collectors::SymbolIndexCollector, :no_db do
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
    it "returns symbol_index" do
      expect(collector.collector_type).to eq("symbol_index")
    end
  end

  describe "#tool_version" do
    it "returns the ast-grep version string" do
      expect(collector.tool_version).to match(/ast-grep \d+\.\d+\.\d+/)
    end

    context "when ast-grep is not installed" do
      before do
        allow(Open3).to receive(:capture3)
          .with("ast-grep", "--version")
          .and_raise(Errno::ENOENT)
      end

      it "returns nil" do
        expect(collector.tool_version).to be_nil
      end
    end
  end

  describe "#collect" do
    let(:artifacts) { collector.collect }

    it "extracts class definitions" do
      class_artifacts = artifacts.select { |a| a[:metadata][:symbol_type] == "class" }
      names = class_artifacts.map { |a| a[:metadata][:name] }

      expect(names).to include("SampleClass", "AnotherClass")
    end

    it "extracts module definitions" do
      module_artifacts = artifacts.select { |a| a[:metadata][:symbol_type] == "module" }
      names = module_artifacts.map { |a| a[:metadata][:name] }

      expect(names).to include("SampleModule")
    end

    it "extracts method definitions" do
      method_artifacts = artifacts.select { |a| a[:metadata][:symbol_type] == "method" }
      names = method_artifacts.map { |a| a[:metadata][:name] }

      expect(names).to include("initialize", "greet", "farewell", "perform")
    end

    it "sets artifact_type to symbol" do
      expect(artifacts).to all(include(artifact_type: "symbol"))
    end

    it "includes a definition chunk for each artifact" do
      artifacts.each do |artifact|
        expect(artifact[:chunks].length).to eq(1)
        expect(artifact[:chunks].first[:chunk_type]).to eq("definition")
      end
    end

    it "builds identifiers with file path" do
      method_artifacts = artifacts.select { |a| a[:metadata][:symbol_type] == "method" }
      identifiers = method_artifacts.map { |a| a[:identifier] }

      expect(identifiers).to include(a_string_matching(/sample\.rb#greet/))
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
