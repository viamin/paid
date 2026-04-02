# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Collectors::RoutesCollector, :no_db do
  subject(:collector) do
    described_class.new(
      project: project,
      project_version: project_version,
      collector_run: collector_run,
      options: { routes_file: fixture_file }
    )
  end

  let(:project) { Struct.new(:id).new(1) }
  let(:project_version) { Struct.new(:id).new(1) }
  let(:collector_run) { Struct.new(:id).new(1) }
  let(:fixture_file) { Rails.root.join("spec/fixtures/knowledge/routes_expanded.txt").to_s }

  describe "#collector_type" do
    it "returns routes" do
      expect(collector.collector_type).to eq("routes")
    end
  end

  describe "#collect" do
    let(:artifacts) { collector.collect }

    it "sets artifact_type to route" do
      expect(artifacts).to all(include(artifact_type: "route"))
    end

    it "sets scope_path to config/routes.rb" do
      expect(artifacts).to all(include(scope_path: "config/routes.rb"))
    end

    it "extracts all routes from the fixture" do
      expect(artifacts.length).to eq(11)
    end

    it "builds identifiers with verb and path" do
      identifiers = artifacts.map { |a| a[:identifier] }

      expect(identifiers).to include(
        "POST /api/users",
        "GET /api/users",
        "GET /dashboard",
        "DELETE /api/users/:id"
      )
    end

    it "strips format suffix from URIs" do
      artifacts.each do |artifact|
        expect(artifact[:metadata][:path]).not_to include("(.:format)")
      end
    end

    it "includes controller and action in metadata" do
      post_route = artifacts.find { |a| a[:identifier] == "POST /api/users" }

      expect(post_route[:metadata]).to include(
        http_method: "POST",
        path: "/api/users",
        controller: "api/users",
        action: "create"
      )
    end

    it "includes prefix in metadata when present" do
      post_route = artifacts.find { |a| a[:identifier] == "POST /api/users" }

      expect(post_route[:metadata][:prefix]).to eq("api_users")
    end

    it "builds human-readable content" do
      post_route = artifacts.find { |a| a[:identifier] == "POST /api/users" }

      expect(post_route[:content]).to include("POST /api/users")
      expect(post_route[:content]).to include("api/users#create")
    end

    it "produces one definition chunk per artifact" do
      artifacts.each do |artifact|
        expect(artifact[:chunks].length).to eq(1)
        expect(artifact[:chunks].first[:chunk_type]).to eq("definition")
      end
    end

    it "builds embeddable chunk content" do
      post_route = artifacts.find { |a| a[:identifier] == "POST /api/users" }
      chunk_content = post_route[:chunks].first[:content]

      expect(chunk_content).to include("Route: POST /api/users")
      expect(chunk_content).to include("Controller: api/users#create")
    end

    it "produces idempotent results" do
      first_run = collector.collect
      second_run = collector.collect

      expect(first_run).to eq(second_run)
    end

    context "when routes file does not exist and not containerized" do
      let(:failing_collector) do
        described_class.new(
          project: project,
          project_version: project_version,
          collector_run: collector_run,
          options: { routes_file: "/nonexistent/path/routes.txt" }
        )
      end

      it "returns empty array for non-Rails repos" do
        allow(failing_collector).to receive(:repo_file_exists?).and_return(false)

        expect(failing_collector.collect).to eq([])
      end
    end

    context "when routes file is empty" do
      before do
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with(fixture_file).and_return(true)
        allow(File).to receive(:read).and_call_original
        allow(File).to receive(:read).with(fixture_file).and_return("")
      end

      it "returns empty array" do
        expect(collector.collect).to eq([])
      end
    end

    context "when generating routes via command in container" do
      let(:container_runner) { instance_double(Knowledge::ContainerizedRunner, host_repo_dir: "/tmp/repo") }
      let(:command_collector) do
        described_class.new(
          project: project,
          project_version: project_version,
          collector_run: collector_run,
          options: { container_runner: container_runner }
        )
      end

      let(:fixture_output) { File.read(fixture_file) }

      before do
        allow(command_collector).to receive(:repo_file_exists?)
          .with("config/routes.rb").and_return(true)
        allow(command_collector).to receive(:repo_file_exists?)
          .with("bin/rails").and_return(true)
      end

      it "runs bin/rails routes --expanded" do
        allow(command_collector).to receive(:run_command)
          .with("bin/rails", "routes", "--expanded", timeout: 60)
          .and_return(fixture_output)

        expect(command_collector.collect.length).to eq(11)
      end

      it "raises when the command fails" do
        allow(command_collector).to receive(:run_command)
          .and_raise(RuntimeError, "Command failed")

        expect { command_collector.collect }.to raise_error(RuntimeError, "Command failed")
      end

      it "returns empty array when config/routes.rb is missing" do
        allow(command_collector).to receive(:repo_file_exists?)
          .with("config/routes.rb").and_return(false)
        allow(command_collector).to receive(:repo_file_exists?)
          .with("bin/rails").and_return(true)

        expect(command_collector.collect).to eq([])
      end

      it "returns empty array when bin/rails binstub is missing" do
        allow(command_collector).to receive(:repo_file_exists?)
          .with("config/routes.rb").and_return(true)
        allow(command_collector).to receive(:repo_file_exists?)
          .with("bin/rails").and_return(false)

        expect(command_collector.collect).to eq([])
      end
    end

    context "when not containerized" do
      let(:non_container_collector) do
        described_class.new(
          project: project,
          project_version: project_version,
          collector_run: collector_run,
          options: {}
        )
      end

      it "returns empty array when Rails indicators are absent" do
        allow(non_container_collector).to receive(:repo_file_exists?).and_return(false)

        expect(non_container_collector.collect).to eq([])
      end

      it "returns empty array when only config/routes.rb is present" do
        allow(non_container_collector).to receive(:repo_file_exists?)
          .with("config/routes.rb").and_return(true)
        allow(non_container_collector).to receive(:repo_file_exists?)
          .with("bin/rails").and_return(false)

        expect(non_container_collector.collect).to eq([])
      end

      it "raises when Rails indicators are present" do
        allow(non_container_collector).to receive(:repo_file_exists?).and_return(true)

        expect { non_container_collector.collect }.to raise_error(
          RuntimeError, /requires containerized mode/
        )
      end
    end
  end
end
