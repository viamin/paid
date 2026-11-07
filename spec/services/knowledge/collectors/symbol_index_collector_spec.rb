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
      tool_version = collector.tool_version
      skip("ast-grep not installed; skipping tool_version spec") if tool_version.nil? || tool_version.empty?
      expect(tool_version).to match(/ast-grep \d+\.\d+\.\d+/)
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
    context "with ast-grep installed" do
      before do
        skip "ast-grep not installed; skipping integration specs" if collector.tool_version.nil?
      end

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
        expect(names.count("initialize")).to eq(2)
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

      it "builds fully-qualified identifiers with enclosing module and class" do
        method_artifacts = artifacts.select { |a| a[:metadata][:symbol_type] == "method" }
        identifiers = method_artifacts.map { |a| a[:identifier] }

        expect(identifiers).to include(a_string_matching(/sample\.rb::SampleModule::SampleClass#greet/))
      end

      it "builds fully-qualified identifiers for nested classes" do
        class_artifacts = artifacts.select { |a| a[:metadata][:symbol_type] == "class" }
        identifiers = class_artifacts.map { |a| a[:identifier] }

        expect(identifiers).to include(a_string_matching(/sample\.rb::SampleModule::SampleClass/))
        expect(identifiers).to include(a_string_matching(/sample\.rb::SampleModule::AnotherClass/))
      end

      it "produces unique identifiers for same-named methods in different classes" do
        init_artifacts = artifacts.select { |a| a[:metadata][:name] == "initialize" }
        identifiers = init_artifacts.map { |a| a[:identifier] }

        expect(identifiers.uniq.size).to eq(identifiers.size)
      end

      it "produces idempotent results" do
        first_run = collector.collect
        second_run = collector.collect

        expect(first_run).to eq(second_run)
      end
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

  # @spec KNOWLEDGE-014
  describe "#each_page" do
    def collector_for(scan_path)
      described_class.new(
        project: project,
        project_version: project_version,
        collector_run: collector_run,
        options: { scan_path: scan_path }
      )
    end

    it "uses a stable cursor and yields bounded file artifacts" do
      stub_const("Knowledge::Collectors::SymbolIndexCollector::FILES_PER_PAGE", 1)
      cursor = nil
      paths = []

      loop do
        artifacts, next_cursor = collector.each_page(cursor: cursor)
        paths.concat(artifacts.map { |artifact| artifact[:scope_path] })
        break unless next_cursor

        expect(next_cursor).to be > cursor.to_s unless cursor.nil?
        cursor = next_cursor
      end

      expect(paths).to all(end_with(".rb"))
      expect(paths).to include("sample.rb")
    end

    it "batches ast-grep into one run per pattern per page instead of per file" do
      Dir.mktmpdir("symbol-index-page-spec") do |dir|
        3.times { |i| File.write(File.join(dir, "file#{i}.rb"), "class C#{i}\nend\n") }
        ast_grep_runs = []
        allow(Open3).to receive(:capture3) do |*cmd|
          ast_grep_runs << cmd if cmd.first == "ast-grep" && cmd[1] == "run"
          [ "[]", "", instance_double(Process::Status, success?: true, exitstatus: 0) ]
        end

        artifacts, next_cursor = collector_for(dir).each_page
        artifacts.to_a

        expect(next_cursor).to be_nil
        expect(ast_grep_runs.size).to eq(described_class::PATTERNS.fetch(:ruby).size)
      end
    end

    it "yields duplicate matched content once per page" do
      skip "ast-grep not installed; skipping integration specs" if collector.tool_version.nil?

      Dir.mktmpdir("symbol-index-page-spec") do |dir|
        File.write(File.join(dir, "a.rb"), "class Alpha\n  def initialize\n  end\nend\n")
        File.write(File.join(dir, "b.rb"), "class Beta\n  def initialize\n  end\nend\n")

        artifacts, _next_cursor = collector_for(dir).each_page

        contents = artifacts.to_a.map { |artifact| artifact[:content] }
        expect(contents.select { |content| content.start_with?("def initialize") }.size).to eq(1)
        expect(contents).to include(a_string_starting_with("class Alpha"), a_string_starting_with("class Beta"))
      end
    end
  end

  # @spec KNOWLEDGE-014
  describe "#collect_page" do
    it "deduplicates identical matched content across files in the page" do
      skip "ast-grep not installed; skipping integration specs" if collector.tool_version.nil?

      Dir.mktmpdir("symbol-index-page-spec") do |dir|
        File.write(File.join(dir, "a.rb"), "class Alpha\n  def initialize\n  end\nend\n")
        File.write(File.join(dir, "b.rb"), "class Beta\n  def initialize\n  end\nend\n")
        page_collector = described_class.new(
          project: project,
          project_version: project_version,
          collector_run: collector_run,
          options: { scan_path: dir }
        )

        artifacts, next_cursor = page_collector.collect_page

        expect(next_cursor).to be_nil
        expect(artifacts.map { |artifact| artifact[:content] })
          .to contain_exactly(
            a_string_starting_with("class Alpha"),
            a_string_starting_with("class Beta"),
            a_string_starting_with("def initialize")
          )
      end
    end
  end
end
