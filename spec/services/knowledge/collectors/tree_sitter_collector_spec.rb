# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Collectors::TreeSitterCollector, :no_db do
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
    it "returns tree_sitter" do
      expect(collector.collector_type).to eq("tree_sitter")
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

      it "sets artifact_type to structure" do
        expect(artifacts).to all(include(artifact_type: "structure"))
      end

      it "includes a definition chunk for each artifact" do
        artifacts.each do |artifact|
          expect(artifact[:chunks].length).to eq(1)
          expect(artifact[:chunks].first[:chunk_type]).to eq("definition")
        end
      end

      it "produces idempotent results" do
        first_run = collector.collect
        second_run = collector.collect

        expect(first_run).to eq(second_run)
      end

      context "with Ruby files" do
        let(:ruby_artifacts) { artifacts.select { |a| a[:metadata][:language] == "ruby" } }

        it "extracts class definitions" do
          classes = ruby_artifacts.select { |a| a[:metadata][:element_type] == "class" }
          names = classes.map { |a| a[:metadata][:name] }

          expect(names).to include("SampleClass", "AnotherClass")
        end

        it "extracts module definitions" do
          modules = ruby_artifacts.select { |a| a[:metadata][:element_type] == "module" }
          names = modules.map { |a| a[:metadata][:name] }

          expect(names).to include("SampleModule")
        end

        it "extracts method definitions" do
          methods = ruby_artifacts.select { |a| a[:metadata][:element_type] == "method" }
          names = methods.map { |a| a[:metadata][:name] }

          expect(names).to include("initialize", "greet", "farewell", "perform")
        end

        it "detects class inheritance" do
          # SampleClass and AnotherClass do not extend anything in sample.rb
          classes = ruby_artifacts.select { |a| a[:metadata][:element_type] == "class" }
          expect(classes).to all(satisfy { |a| a[:metadata][:parent].nil? })
        end

        it "detects snake_case naming for methods" do
          methods = ruby_artifacts.select { |a| a[:metadata][:element_type] == "method" }
          styles = methods.map { |a| a[:metadata][:naming_style] }

          expect(styles).to all(eq("snake"))
        end

        it "detects PascalCase naming for classes" do
          classes = ruby_artifacts.select { |a| a[:metadata][:element_type] == "class" }
          styles = classes.map { |a| a[:metadata][:naming_style] }

          expect(styles).to all(eq("pascal"))
        end

        it "includes line count metadata" do
          methods = ruby_artifacts.select { |a| a[:metadata][:element_type] == "method" }

          methods.each do |m|
            expect(m[:metadata][:line_count]).to be_a(Integer)
            expect(m[:metadata][:line_count]).to be >= 1
          end
        end

        it "preserves line ranges for deep-linking" do
          greet = ruby_artifacts.find { |a| a[:metadata][:name] == "greet" }

          expect(greet[:metadata][:start_line]).to eq(9)
          expect(greet[:metadata][:end_line]).to eq(11)
          expect(greet[:metadata][:chunking_strategy]).to eq("ast")
        end
      end

      context "with TypeScript files" do
        let(:ts_artifacts) { artifacts.select { |a| a[:metadata][:language] == "typescript" } }

        it "extracts class definitions" do
          classes = ts_artifacts.select { |a| a[:metadata][:element_type] == "class" }
          names = classes.map { |a| a[:metadata][:name] }

          expect(names).to include("Person")
        end

        it "extracts interface definitions" do
          interfaces = ts_artifacts.select { |a| a[:metadata][:element_type] == "interface" }
          names = interfaces.map { |a| a[:metadata][:name] }

          expect(names).to include("Greeter")
        end

        it "extracts function definitions" do
          functions = ts_artifacts.select { |a| a[:metadata][:element_type] == "function" }
          names = functions.map { |a| a[:metadata][:name] }

          expect(names).to include("createPerson")
        end

        it "detects class inheritance" do
          person = ts_artifacts.find { |a| a[:metadata][:name] == "Person" }

          expect(person[:metadata][:parent]).to eq("BaseEntity")
        end

        it "detects camelCase naming for functions" do
          create_fn = ts_artifacts.find { |a| a[:metadata][:name] == "createPerson" }

          expect(create_fn[:metadata][:naming_style]).to eq("camel")
        end
      end

      context "with Python files" do
        let(:py_artifacts) { artifacts.select { |a| a[:metadata][:language] == "python" } }

        it "extracts class definitions" do
          classes = py_artifacts.select { |a| a[:metadata][:element_type] == "class" }
          names = classes.map { |a| a[:metadata][:name] }

          expect(names).to include("Animal", "Dog")
        end

        it "extracts function definitions" do
          functions = py_artifacts.select { |a| a[:metadata][:element_type] == "function" }
          names = functions.map { |a| a[:metadata][:name] }

          expect(names).to include("create_animal")
        end

        it "detects class inheritance for Dog" do
          dog = py_artifacts.find { |a| a[:metadata][:name] == "Dog" && a[:metadata][:element_type] == "class" }

          expect(dog[:metadata][:params]).to include("Animal")
        end
      end

      context "with Go files" do
        let(:go_artifacts) { artifacts.select { |a| a[:metadata][:language] == "go" } }

        it "extracts struct definitions" do
          structs = go_artifacts.select { |a| a[:metadata][:element_type] == "struct" }
          names = structs.map { |a| a[:metadata][:name] }

          expect(names).to include("Dog")
        end

        it "extracts interface definitions" do
          interfaces = go_artifacts.select { |a| a[:metadata][:element_type] == "interface" }
          names = interfaces.map { |a| a[:metadata][:name] }

          expect(names).to include("Animal")
        end

        it "extracts function definitions" do
          functions = go_artifacts.select { |a| a[:metadata][:element_type] == "function" }
          names = functions.map { |a| a[:metadata][:name] }

          expect(names).to include("NewDog")
        end

        it "detects PascalCase naming for exported Go types" do
          dog = go_artifacts.find { |a| a[:metadata][:name] == "Dog" }

          expect(dog[:metadata][:naming_style]).to eq("pascal")
        end
      end

      context "with unsupported source files" do
        let(:fallback_artifact) { artifacts.find { |a| a[:scope_path] == "sample.lua" } }

        it "falls back to file-level chunking" do
          expect(fallback_artifact).to include(
            artifact_type: "structure",
            identifier: "sample.lua::file"
          )
          expect(fallback_artifact[:metadata]).to include(
            language: "lua",
            element_type: "file",
            chunking_strategy: "file_fallback",
            start_line: 1
          )
          expect(fallback_artifact[:chunks]).to contain_exactly(
            hash_including(
              chunk_type: "definition",
              scope_tags: [ "lua", "file", "file_fallback" ]
            )
          )
        end
      end

      it "deduplicates overlapping patterns" do
        # When both "class $NAME" and "class $NAME < $PARENT" match,
        # only the more specific one should be kept
        identifiers = artifacts.map { |a| a[:identifier] }
        expect(identifiers).to eq(identifiers.uniq)
      end
    end

    context "when ast-grep returns no results" do
      before do
        allow(Open3).to receive(:capture3).and_return(
          [ "[]", "", instance_double(Process::Status, success?: true, exitstatus: 0) ]
        )
      end

      it "returns file-level fallback artifacts" do
        expect(collector.collect).to include(
          hash_including(
            scope_path: "sample.rb",
            identifier: "sample.rb::file",
            metadata: hash_including(chunking_strategy: "file_fallback")
          )
        )
      end
    end

    context "when ast-grep is not installed" do
      before do
        allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)
      end

      it "returns file-level fallback artifacts" do
        expect(collector.collect).to include(
          hash_including(
            scope_path: "sample.ts",
            identifier: "sample.ts::file",
            metadata: hash_including(chunking_strategy: "file_fallback")
          )
        )
      end

      it "skips reading files whose extensions cannot produce fallback artifacts" do
        txt_path = File.join(fixture_path, "notes.txt")
        rb_path = File.join(fixture_path, "sample.rb")

        allow(Find).to receive(:find).with(fixture_path).and_yield(txt_path).and_yield(rb_path)
        allow(File).to receive(:directory?).with(txt_path).and_return(false)
        allow(File).to receive(:directory?).with(rb_path).and_return(false)
        allow(File).to receive(:binread).with(rb_path, 1024).and_call_original
        allow(File).to receive(:read).with(rb_path).and_call_original
        allow(File).to receive(:binread).with(txt_path, 1024).and_call_original
        allow(File).to receive(:read).with(txt_path).and_call_original

        collector.collect

        expect(File).not_to have_received(:binread).with(txt_path, 1024)
        expect(File).not_to have_received(:read).with(txt_path)
        expect(File).to have_received(:binread).with(rb_path, 1024)
        expect(File).to have_received(:read).with(rb_path)
      end

      it "skips reading files already covered by AST artifacts" do
        rb_path = File.join(fixture_path, "sample.rb")
        lua_path = File.join(fixture_path, "sample.lua")

        allow(Find).to receive(:find).with(fixture_path).and_yield(rb_path).and_yield(lua_path)
        allow(File).to receive(:directory?).with(rb_path).and_return(false)
        allow(File).to receive(:directory?).with(lua_path).and_return(false)
        allow(File).to receive(:binread).with(lua_path, 1024).and_call_original
        allow(File).to receive(:read).with(lua_path).and_call_original
        allow(File).to receive(:binread).with(rb_path, 1024).and_call_original
        allow(File).to receive(:read).with(rb_path).and_call_original

        repo_files = collector.send(:repo_files, exclude_paths: Set["sample.rb"])

        expect(File).not_to have_received(:binread).with(rb_path, 1024)
        expect(File).not_to have_received(:read).with(rb_path)
        expect(File).to have_received(:binread).with(lua_path, 1024)
        expect(File).to have_received(:read).with(lua_path)
        expect(repo_files).to contain_exactly(
          hash_including(relative_path: "sample.lua", language: :lua)
        )
      end

      it "skips oversized supported source files instead of building nil-content artifacts" do
        rb_path = File.join(fixture_path, "sample.rb")

        allow(Find).to receive(:find).with(fixture_path).and_yield(rb_path)
        allow(File).to receive(:directory?).with(rb_path).and_return(false)
        allow(File).to receive(:size).with(rb_path)
          .and_return(described_class::MAX_FALLBACK_FILE_BYTES + 1)
        allow(File).to receive(:read).with(rb_path).and_call_original

        expect(collector.collect).to eq([])
        expect(File).not_to have_received(:read).with(rb_path)
      end

      it "prunes ignored directories before visiting their files" do
        ignored_dir = File.join(fixture_path, "node_modules")
        ignored_file = File.join(ignored_dir, "ignored.js")
        root_basename = File.basename(fixture_path)

        allow(Find).to receive(:find).with(fixture_path)
          .and_yield(fixture_path)
          .and_yield(ignored_dir)
          .and_yield(ignored_file)
        allow(File).to receive(:directory?).with(fixture_path).and_return(true)
        allow(File).to receive(:directory?).with(ignored_dir).and_return(true)
        allow(File).to receive(:directory?).with(ignored_file).and_return(false)
        allow(File).to receive(:basename).and_call_original
        allow(File).to receive(:basename).with(fixture_path).and_return(root_basename)
        allow(File).to receive(:basename).with(ignored_dir).and_return("node_modules")
        allow(Find).to receive(:prune)
        allow(File).to receive(:binread).with(ignored_file, 1024).and_call_original

        collector.send(:repo_files)

        expect(Find).to have_received(:prune)
        expect(File).not_to have_received(:binread).with(ignored_file, 1024)
      end
    end
  end

  # @spec KNOWLEDGE-014
  describe "#collect_page" do
    it "visits each eligible file once in bounded pages" do
      stub_const("Knowledge::Collectors::TreeSitterCollector::FILES_PER_PAGE", 1)
      cursors = []
      all_artifacts = []
      cursor = nil

      loop do
        artifacts, next_cursor = collector.collect_page(cursor: cursor)
        all_artifacts.concat(artifacts)
        break unless next_cursor

        expect(cursors).not_to include(next_cursor)
        cursors << next_cursor
        cursor = next_cursor
      end

      expect(cursors).not_to be_empty
      expect(all_artifacts.map { |artifact| artifact[:scope_path] }.uniq).to include("sample.rb")
      expect(all_artifacts.size).to be > 0
      expect(all_artifacts.map { |artifact| Digest::SHA256.hexdigest(artifact[:content]) }.uniq)
        .to match_array(collector.collect.map { |artifact| Digest::SHA256.hexdigest(artifact[:content]) })
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

    it "batches ast-grep into one run per pattern per page instead of per file" do
      Dir.mktmpdir("tree-sitter-page-spec") do |dir|
        3.times { |i| File.write(File.join(dir, "file#{i}.rb"), "class C#{i}\nend\n") }
        ast_grep_runs = []
        allow(Open3).to receive(:capture3) do |*cmd|
          ast_grep_runs << cmd if cmd.first == "ast-grep" && cmd[1] == "run"
          [ "[]", "", instance_double(Process::Status, success?: true, exitstatus: 0) ]
        end

        artifacts, next_cursor = collector_for(dir).each_page
        artifacts.to_a

        expect(next_cursor).to be_nil
        expect(ast_grep_runs.size).to eq(described_class::LANGUAGE_CONFIG[:ruby][:patterns].size)
      end
    end

    it "yields duplicate matched content once per page" do
      skip "ast-grep not installed; skipping integration specs" if collector.tool_version.nil?

      Dir.mktmpdir("tree-sitter-page-spec") do |dir|
        File.write(File.join(dir, "a.rb"), "class Alpha\n  def initialize\n  end\nend\n")
        File.write(File.join(dir, "b.rb"), "class Beta\n  def initialize\n  end\nend\n")

        artifacts, _next_cursor = collector_for(dir).each_page

        contents = artifacts.to_a.map { |artifact| artifact[:content] }
        expect(contents.select { |content| content.start_with?("def initialize") }.size).to eq(1)
        expect(contents).to include(a_string_starting_with("class Alpha"), a_string_starting_with("class Beta"))
      end
    end
  end
end
