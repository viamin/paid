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
    context "with ast-grep installed" do
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
