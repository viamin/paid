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

  let(:project) { instance_double(Project, id: 1, github_token: github_token) }
  let(:project_version) { Struct.new(:id).new(1) }
  let(:collector_run) { Struct.new(:id).new(1) }
  let(:fixture_file) { Rails.root.join("spec/fixtures/knowledge/routes_expanded.txt").to_s }
  let(:github_token) { nil }

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

      it "raises SkipCollector" do
        expect { failing_collector.collect }.to raise_error(Knowledge::SkipCollector)
      end
    end

    context "when routes file is empty" do
      before do
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with(fixture_file).and_return(true)
        allow(File).to receive(:read).and_call_original
        allow(File).to receive(:read).with(fixture_file).and_return("")
      end

      it "raises SkipCollector" do
        expect { collector.collect }.to raise_error(Knowledge::SkipCollector)
      end
    end

    context "when generating routes via command in container" do
      let(:container_runner) do
        instance_double(
          Knowledge::ContainerizedRunner,
          host_repo_dir: "/tmp/repo",
          options: { workspace_mount: "/workspace" },
          connect_network!: nil,
          disconnect_network!: nil
        )
      end
      let(:command_collector) do
        described_class.new(
          project: project,
          project_version: project_version,
          collector_run: collector_run,
          options: { container_runner: container_runner }
        )
      end

      let(:fixture_output) { File.read(fixture_file) }
      let(:active_github_token) do
        instance_double(
          GithubToken,
          active?: true,
          token: "github_pat_test_token",
          touch_last_used!: true
        )
      end

      before do
        allow(command_collector).to receive(:repo_file_exists?)
          .with("config/routes.rb").and_return(true)
        allow(command_collector).to receive(:repo_file_exists?)
          .with("bin/rails").and_return(true)
        allow(command_collector).to receive(:repo_file_exists?)
          .with("Gemfile").and_return(true)
        allow(command_collector).to receive(:run_command)
          .with("sh", "-c", /bundle install/, timeout: 300, env: kind_of(Hash))
          .and_return("")
        allow(command_collector).to receive(:run_command)
          .with("sh", "-c", /rm -rf \/tmp\/paid-bundle-home.*! test -e \/tmp\/paid-bundle-home/, timeout: 10, env: { "HOME" => "/tmp/paid-bundle-home" })
          .and_return("")
      end

      it "runs bundle install before bin/rails routes" do
        allow(command_collector).to receive(:run_command)
          .with("sh", "-c", /bin\/rails routes --expanded/, timeout: 120, env: kind_of(Hash))
          .and_return(fixture_output)

        command_collector.collect

        expect(command_collector).to have_received(:run_command)
          .with("sh", "-c", /bundle install/, timeout: 300, env: kind_of(Hash))
      end

      it "runs bin/rails routes --expanded" do
        allow(command_collector).to receive(:run_command)
          .with("sh", "-c", /bin\/rails routes --expanded/, timeout: 120, env: kind_of(Hash))
          .and_return(fixture_output)

        expect(command_collector.collect.length).to eq(11)
      end

      it "passes through the configured DATABASE_URL when present" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("DATABASE_URL").and_return("sqlite3:storage/test.sqlite3")
        allow(command_collector).to receive(:run_command)
          .with("sh", "-c", /bin\/rails routes --expanded/, timeout: 120, env: kind_of(Hash))
          .and_return(fixture_output)

        command_collector.collect

        expect(command_collector).to have_received(:run_command).with(
          "sh", "-c", /bin\/rails routes --expanded/,
          timeout: 120,
          env: hash_including("DATABASE_URL" => "sqlite3:storage/test.sqlite3")
        )
      end

      it "does not inject DATABASE_URL when none is configured" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("DATABASE_URL").and_return(nil)
        allow(command_collector).to receive(:run_command)
          .with("sh", "-c", /bin\/rails routes --expanded/, timeout: 120, env: kind_of(Hash))
          .and_return(fixture_output)

        command_collector.collect

        expect(command_collector).to have_received(:run_command).with(
          "sh", "-c", /bin\/rails routes --expanded/,
          timeout: 120,
          env: satisfy { |env| !env.key?("DATABASE_URL") }
        )
      end

      it "raises when the command fails with a non-database error" do
        allow(command_collector).to receive(:run_command)
          .with("sh", "-c", /bin\/rails routes --expanded/, timeout: 120, env: kind_of(Hash))
          .and_raise(RuntimeError, "Command failed")

        expect { command_collector.collect }.to raise_error(RuntimeError, "Command failed")
      end

      it "fails when the command hits a database connection error" do
        allow(command_collector).to receive(:run_command)
          .with("sh", "-c", /bin\/rails routes --expanded/, timeout: 120, env: kind_of(Hash))
          .and_raise(
            Knowledge::ContainerizedRunner::ContainerError,
            'Command failed (exit 1): ActiveRecord::ConnectionNotEstablished connection to server on socket "/var/run/postgresql/.s.PGSQL.5432" failed'
          )

        expect { command_collector.collect }.to raise_error(
          Knowledge::ContainerizedRunner::ContainerError,
          /ActiveRecord::ConnectionNotEstablished/
        )
      end

      it "cleans up credentials and disconnects network before running routes" do
        allow(command_collector).to receive(:run_command)
          .with("sh", "-c", /bin\/rails routes --expanded/, timeout: 120, env: kind_of(Hash))
          .and_return(fixture_output)

        command_collector.collect

        expect(container_runner).to have_received(:connect_network!).ordered
        expect(command_collector).to have_received(:run_command)
          .with("sh", "-c", /bundle install/, timeout: 300, env: kind_of(Hash)).ordered
        expect(command_collector).to have_received(:run_command)
          .with("sh", "-c", /rm -rf \/tmp\/paid-bundle-home.*! test -e \/tmp\/paid-bundle-home/, timeout: 10, env: { "HOME" => "/tmp/paid-bundle-home" }).ordered
        expect(container_runner).to have_received(:disconnect_network!).ordered
        expect(command_collector).to have_received(:run_command)
          .with("sh", "-c", /bin\/rails routes --expanded/, timeout: 120, env: kind_of(Hash)).ordered
      end

      it "disconnects network even when bundle install fails" do
        allow(command_collector).to receive(:run_command)
          .with("sh", "-c", /bundle install/, timeout: 300, env: kind_of(Hash))
          .and_raise(RuntimeError, "bundle install failed")

        expect { command_collector.collect }.to raise_error(RuntimeError, "bundle install failed")
        expect(command_collector).to have_received(:run_command)
          .with("sh", "-c", /rm -rf \/tmp\/paid-bundle-home.*! test -e \/tmp\/paid-bundle-home/, timeout: 10, env: { "HOME" => "/tmp/paid-bundle-home" })
        expect(container_runner).to have_received(:disconnect_network!)
      end

      it "preserves bundle install errors when cleanup also fails" do
        allow(command_collector).to receive(:run_command)
          .with("sh", "-c", /bundle install/, timeout: 300, env: kind_of(Hash))
          .and_raise(RuntimeError, "bundle install timed out")
        allow(command_collector).to receive(:run_command)
          .with("sh", "-c", /rm -rf \/tmp\/paid-bundle-home.*! test -e \/tmp\/paid-bundle-home/, timeout: 10, env: { "HOME" => "/tmp/paid-bundle-home" })
          .and_raise(Knowledge::ContainerizedRunner::ContainerError, "cleanup failed after timeout")

        expect { command_collector.collect }.to raise_error(RuntimeError, "bundle install timed out")
        expect(container_runner).to have_received(:disconnect_network!)
      end

      it "preserves bundle install errors when disconnect also fails" do
        allow(command_collector).to receive(:run_command)
          .with("sh", "-c", /bundle install/, timeout: 300, env: kind_of(Hash))
          .and_raise(RuntimeError, "bundle install timed out")
        allow(container_runner).to receive(:disconnect_network!)
          .and_raise(Knowledge::ContainerizedRunner::ContainerError, "disconnect failed after timeout")

        expect { command_collector.collect }.to raise_error(RuntimeError, "bundle install timed out")
      end

      it "fails when bundle install raises a git-sourced gem error" do
        allow(command_collector).to receive(:run_command)
          .with("sh", "-c", /bundle install/, timeout: 300, env: kind_of(Hash))
          .and_raise(RuntimeError, "Bundler::GitError: repo is not yet checked out")

        expect { command_collector.collect }.to raise_error(
          RuntimeError, /Bundler::GitError/
        )
        expect(container_runner).to have_received(:disconnect_network!)
      end

      it "does not forward project github tokens into bundle install" do
        allow(project).to receive(:github_token).and_return(active_github_token)
        allow(command_collector).to receive(:run_command)
          .with("sh", "-c", /bin\/rails routes --expanded/, timeout: 120, env: kind_of(Hash))
          .and_return(fixture_output)

        command_collector.collect

        expect(command_collector).to have_received(:run_command).with(
          "sh", "-c", /bundle install/,
          timeout: 300,
          env: satisfy { |env|
            env["HOME"] == "/tmp/paid-bundle-home" &&
              !env.key?("PAID_GITHUB_TOKEN") &&
              !env.key?("BUNDLE_GITHUB__COM")
          }
        )
        expect(active_github_token).not_to have_received(:touch_last_used!)
      end

      it "skips bundle install when Gemfile is absent" do
        allow(command_collector).to receive(:repo_file_exists?)
          .with("Gemfile").and_return(false)
        allow(command_collector).to receive(:run_command)
          .with("sh", "-c", /bin\/rails routes --expanded/, timeout: 120, env: kind_of(Hash))
          .and_return(fixture_output)

        command_collector.collect

        expect(command_collector).not_to have_received(:run_command)
          .with("sh", "-c", /bundle install/, timeout: 300, env: kind_of(Hash))
      end

      it "uses git url rewrites without writing a github token file" do
        install_cmd = command_collector.send(:install_bundle_command)
        expect(install_cmd).to include('git config --global --add url.\"https://github.com/\".insteadOf ssh://git@github.com/')
        expect(install_cmd).to include('git config --global --add url.\"https://github.com/\".insteadOf git@github.com:')
        expect(install_cmd).not_to include(".netrc")
        expect(install_cmd).not_to include("PAID_GITHUB_TOKEN")
      end

      it "removes the temporary credential home after bundle install" do
        allow(command_collector).to receive(:run_command)
          .with("sh", "-c", /bin\/rails routes --expanded/, timeout: 120, env: kind_of(Hash))
          .and_return(fixture_output)

        command_collector.collect

        expect(command_collector).to have_received(:run_command)
          .with("sh", "-c", /rm -rf \/tmp\/paid-bundle-home.*! test -e \/tmp\/paid-bundle-home/, timeout: 10, env: { "HOME" => "/tmp/paid-bundle-home" })
      end

      it "aborts when credential cleanup fails" do
        allow(command_collector).to receive(:run_command)
          .with("sh", "-c", /rm -rf \/tmp\/paid-bundle-home.*! test -e \/tmp\/paid-bundle-home/, timeout: 10, env: { "HOME" => "/tmp/paid-bundle-home" })
          .and_raise(RuntimeError, "credential cleanup verification failed")

        expect { command_collector.collect }.to raise_error(
          RuntimeError, /credential cleanup verification failed/
        )
        expect(command_collector).not_to have_received(:run_command)
          .with("sh", "-c", /bin\/rails routes --expanded/, timeout: 120, env: kind_of(Hash))
        expect(container_runner).to have_received(:disconnect_network!)
      end

      it "preserves network connect errors without attempting cleanup or disconnect" do
        allow(container_runner).to receive(:connect_network!)
          .and_raise(Knowledge::ContainerizedRunner::ContainerError, "Failed to connect network: boom")

        expect { command_collector.collect }.to raise_error(
          Knowledge::ContainerizedRunner::ContainerError, /Failed to connect network: boom/
        )
        expect(command_collector).not_to have_received(:run_command)
          .with("sh", "-c", /bundle install/, timeout: 300, env: kind_of(Hash))
        expect(command_collector).not_to have_received(:run_command)
          .with("sh", "-c", /rm -rf \/tmp\/paid-bundle-home.*! test -e \/tmp\/paid-bundle-home/, timeout: 10, env: { "HOME" => "/tmp/paid-bundle-home" })
        expect(container_runner).not_to have_received(:disconnect_network!)
      end

      it "raises SkipCollector when config/routes.rb is missing" do
        allow(command_collector).to receive(:repo_file_exists?)
          .with("config/routes.rb").and_return(false)
        allow(command_collector).to receive(:repo_file_exists?)
          .with("bin/rails").and_return(true)

        expect { command_collector.collect }.to raise_error(
          Knowledge::SkipCollector, /not a Rails project/
        )
      end

      it "raises SkipCollector when bin/rails binstub is missing" do
        allow(command_collector).to receive(:repo_file_exists?)
          .with("config/routes.rb").and_return(true)
        allow(command_collector).to receive(:repo_file_exists?)
          .with("bin/rails").and_return(false)

        expect { command_collector.collect }.to raise_error(
          Knowledge::SkipCollector, /bin\/rails binstub not found/
        )
      end
    end

    context "when not containerized" do
      let(:non_container_collector) do
        described_class.new(
          project: project,
          project_version: project_version,
          collector_run: collector_run,
          options: { scan_path: "/tmp/fake-repo" }
        )
      end

      it "raises SkipCollector when Rails indicators are absent" do
        allow(non_container_collector).to receive(:repo_file_exists?).and_return(false)

        expect { non_container_collector.collect }.to raise_error(
          Knowledge::SkipCollector, /not a Rails project/
        )
      end

      it "raises SkipCollector when only config/routes.rb is present" do
        allow(non_container_collector).to receive(:repo_file_exists?)
          .with("config/routes.rb").and_return(true)
        allow(non_container_collector).to receive(:repo_file_exists?)
          .with("bin/rails").and_return(false)

        expect { non_container_collector.collect }.to raise_error(
          Knowledge::SkipCollector, /bin\/rails binstub not found/
        )
      end

      it "raises when Rails indicators are present" do
        allow(non_container_collector).to receive(:repo_file_exists?).and_return(true)

        expect { non_container_collector.collect }.to raise_error(
          RuntimeError, /requires containerized mode/
        )
      end

      it "raises SkipCollector when repo path is nil" do
        collector_no_path = described_class.new(
          project: project,
          project_version: project_version,
          collector_run: collector_run,
          options: {}
        )
        allow(collector_no_path).to receive(:resolve_repo_path).and_return(nil)

        expect { collector_no_path.collect }.to raise_error(
          Knowledge::SkipCollector, /repository path not available/
        )
      end
    end
  end
end
