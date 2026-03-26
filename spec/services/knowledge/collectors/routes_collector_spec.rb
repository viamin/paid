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

    context "when routes file does not exist" do
      let(:missing_file) { "/nonexistent/path/routes.txt" }
      let(:missing_collector) do
        described_class.new(
          project: project,
          project_version: project_version,
          collector_run: collector_run,
          options: { routes_file: missing_file }
        )
      end

      it "returns empty array" do
        expect(missing_collector.collect).to eq([])
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

    context "with scan_path fallback" do
      let(:scan_dir) { Rails.root.join("spec/fixtures/knowledge").to_s }
      let(:scan_collector) do
        described_class.new(
          project: project,
          project_version: project_version,
          collector_run: collector_run,
          options: { scan_path: scan_dir }
        )
      end

      before do
        # Create tmp/routes_expanded.txt under the scan path
        tmp_dir = File.join(scan_dir, "tmp")
        FileUtils.mkdir_p(tmp_dir)
        FileUtils.cp(fixture_file, File.join(tmp_dir, "routes_expanded.txt"))
      end

      after do
        tmp_dir = File.join(scan_dir, "tmp")
        FileUtils.rm_rf(tmp_dir)
      end

      it "reads from tmp/routes_expanded.txt under scan_path" do
        expect(scan_collector.collect.length).to eq(11)
      end
    end
  end
end
