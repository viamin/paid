# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Collectors::DependencyCollector, :no_db do
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
    it "returns dependency" do
      expect(collector.collector_type).to eq("dependency")
    end
  end

  describe "#collect" do
    let(:artifacts) { collector.collect }

    it "sets artifact_type to dependency" do
      expect(artifacts).to all(include(artifact_type: "dependency"))
    end

    context "with Gemfile" do
      let(:gemfile_artifacts) { artifacts.select { |a| a[:scope_path] == "Gemfile" } }

      it "extracts gems from the Gemfile" do
        names = gemfile_artifacts.map { |a| a[:metadata][:name] }

        expect(names).to include("rails", "pg", "puma")
      end

      it "captures version constraints" do
        rails_dep = gemfile_artifacts.find { |a| a[:metadata][:name] == "rails" }

        expect(rails_dep[:metadata][:version]).to eq("~> 8.1")
        expect(rails_dep[:identifier]).to eq("rails ~> 8.1")
      end

      it "identifies groups" do
        rspec_dep = gemfile_artifacts.find { |a| a[:metadata][:name] == "rspec-rails" }

        expect(rspec_dep[:metadata][:group]).to eq("development, test")
      end

      it "produces one artifact per dependency" do
        expect(gemfile_artifacts.length).to eq(6)
      end

      context "with custom Gemfile content" do
        def stub_gemfile(content)
          allow(File).to receive(:exist?).and_call_original
          allow(File).to receive(:exist?).with("#{fixture_path}/Gemfile").and_return(true)
          allow(File).to receive(:read).and_call_original
          allow(File).to receive(:read).with("#{fixture_path}/Gemfile").and_return(content)
        end

        it "handles parenthesized group syntax" do
          stub_gemfile(<<~GEMFILE)
            source "https://rubygems.org"
            group(:development, :test) do
              gem "rspec"
            end
          GEMFILE

          result = collector.collect
          rspec_dep = result.find { |a| a[:metadata][:name] == "rspec" }

          expect(rspec_dep[:metadata][:group]).to eq("development, test")
        end

        it "handles nested blocks within groups" do
          stub_gemfile(<<~GEMFILE)
            source "https://rubygems.org"
            group :development do
              platforms :ruby do
                gem "nested_gem"
              end
              gem "outer_gem"
            end
            gem "top_level"
          GEMFILE

          result = collector.collect
          groups = result.each_with_object({}) { |a, h| h[a[:metadata][:name]] = a[:metadata][:group] }

          expect(groups["nested_gem"]).to eq("development")
          expect(groups["outer_gem"]).to eq("development")
          expect(groups["top_level"]).to eq("default")
        end

        it "captures multiple version constraints" do
          stub_gemfile(<<~GEMFILE)
            source "https://rubygems.org"
            gem "foo", ">= 1.0", "< 2.0"
          GEMFILE

          result = collector.collect
          foo_dep = result.find { |a| a[:metadata][:name] == "foo" }

          expect(foo_dep[:metadata][:version]).to eq(">= 1.0, < 2.0")
        end
      end
    end

    context "with package.json" do
      let(:package_artifacts) { artifacts.select { |a| a[:scope_path] == "package.json" } }

      it "extracts dependencies from package.json" do
        names = package_artifacts.map { |a| a[:metadata][:name] }

        expect(names).to include("react", "react-dom", "eslint", "prettier")
      end

      it "identifies dev dependencies" do
        eslint_dep = package_artifacts.find { |a| a[:metadata][:name] == "eslint" }

        expect(eslint_dep[:metadata][:group]).to eq("dev")
      end

      it "captures version constraints" do
        react_dep = package_artifacts.find { |a| a[:metadata][:name] == "react" }

        expect(react_dep[:identifier]).to eq("react ^18.2.0")
      end
    end

    context "with requirements.txt" do
      let(:req_artifacts) { artifacts.select { |a| a[:scope_path] == "requirements.txt" } }

      it "extracts Python dependencies" do
        names = req_artifacts.map { |a| a[:metadata][:name] }

        expect(names).to include("django", "requests", "numpy")
      end

      it "captures version constraints" do
        django_dep = req_artifacts.find { |a| a[:metadata][:name] == "django" }

        expect(django_dep[:metadata][:version]).to eq(">=4.2")
      end
    end

    context "with go.mod" do
      let(:go_artifacts) { artifacts.select { |a| a[:scope_path] == "go.mod" } }

      it "extracts Go dependencies" do
        names = go_artifacts.map { |a| a[:metadata][:name] }

        expect(names).to include("github.com/gin-gonic/gin", "github.com/lib/pq")
      end

      it "captures version" do
        gin_dep = go_artifacts.find { |a| a[:metadata][:name] == "github.com/gin-gonic/gin" }

        expect(gin_dep[:metadata][:version]).to eq("v1.9.1")
      end
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
  end
end
