# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::Backends::LocalDocker, :no_db do
  subject(:backend) { described_class.new }

  let(:container) { instance_double(Docker::Container) }
  let(:network) { instance_double(Docker::Network) }
  let(:volume) { instance_double(Docker::Volume) }

  # @spec CONTAINER-RUNTIME-049
  describe "local host memory evidence" do
    before do
      allow(Docker).to receive_messages(info: { "MemTotal" => 16_384 }, url: "unix:///var/run/docker.sock")
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with("/proc/meminfo").and_return("MemTotal: 16 kB\nMemAvailable: 3 kB\n")
    end

    it "includes available VM memory when host and daemon totals match" do
      expect(backend.system_info).to include("PaidHostMemAvailable" => 3_072)
    end

    it "does not substitute the control plane's memory for a different host" do
      allow(Docker).to receive(:info).and_return("MemTotal" => 32_768)
      expect(backend.system_info).not_to have_key("PaidHostMemAvailable")
    end

    it "preserves Docker capacity when procfs is unavailable" do
      allow(File).to receive(:read).with("/proc/meminfo").and_raise(Errno::ENOENT)
      expect(backend.system_info).to eq("MemTotal" => 16_384)
    end

    it "ignores local host memory for a TCP Docker endpoint" do
      allow(Docker).to receive(:url).and_return("tcp://another-host:2376")
      expect(backend.system_info).not_to have_key("PaidHostMemAvailable")
    end

    it "does not invent available memory when the kernel field is missing" do
      allow(File).to receive(:read).with("/proc/meminfo").and_return("MemTotal: 16 kB\n")
      expect(backend.system_info).not_to have_key("PaidHostMemAvailable")
    end

    it "does not hide a Docker socket error as an empty successful system-info response" do
      allow(Docker).to receive(:info).and_raise(Errno::ENOENT)
      expect { backend.system_info }.to raise_error(Errno::ENOENT)
    end

    it "keeps valid Docker evidence when optional host-memory IO fails" do
      allow(File).to receive(:read).with("/proc/meminfo").and_raise(Errno::EIO)
      expect(backend.system_info).to eq("MemTotal" => 16_384)
    end
  end

  describe "backing-storage evidence" do
    def with_backing_store_probe(script, daemon_root: "/var/lib/docker", probe_directory_name: "probe")
      original_path = ENV.fetch("PATH")
      original_probe_path = ENV["PAID_DOCKER_BACKING_STORE_PROBE_PATH"]
      original_daemon_root = ENV["PAID_DOCKER_BACKING_STORE_DAEMON_ROOT"]

      Dir.mktmpdir do |directory|
        probe_path = File.join(directory, probe_directory_name)
        command_path = File.join(directory, "df")
        Dir.mkdir(probe_path)
        File.write(command_path, script)
        File.chmod(0o755, command_path)
        ENV["PATH"] = directory
        ENV["PAID_DOCKER_BACKING_STORE_PROBE_PATH"] = probe_path
        ENV["PAID_DOCKER_BACKING_STORE_DAEMON_ROOT"] = daemon_root
        allow(Docker).to receive_messages(url: "unix:///var/run/docker.sock", info: { "DockerRootDir" => daemon_root })
        allow(Docker::Container).to receive(:get).and_raise(Docker::Error::NotFoundError)
        allow(File).to receive(:read).and_call_original
        allow(File).to receive(:read).with("/proc/self/mountinfo").and_return(mountinfo_for(root: File.join(daemon_root, ".paid-capacity-probe"), target: probe_path))

        yield probe_path
      end
    ensure
      ENV["PATH"] = original_path
      ENV["PAID_DOCKER_BACKING_STORE_PROBE_PATH"] = original_probe_path
      ENV["PAID_DOCKER_BACKING_STORE_DAEMON_ROOT"] = original_daemon_root
    end

    def with_namespace_mapped_probe
      with_backing_store_probe("#!/bin/sh\nprintf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev/test 100 10 90 10%% /mnt\\n'\n") do |probe_path|
        hostname = "a" * 12
        allow(Socket).to receive(:gethostname).and_return(hostname)
        allow(File).to receive(:read).with("/proc/self/mountinfo")
          .and_return(mountinfo_for(root: "/docker/.paid-capacity-probe", target: probe_path))
        info = { "Id" => "a" * 64, "Config" => { "Hostname" => hostname }, "Mounts" => [
          { "Type" => "bind", "Source" => "/var/lib/docker/.paid-capacity-probe", "Destination" => probe_path, "RW" => false }
        ] }
        allow(Docker::Container).to receive(:get).with(hostname)
          .and_return(instance_double(Docker::Container, info:))

        yield info
      end
    end

    # @spec CONTAINER-RUNTIME-055
    it "verifies a bind source when daemon and kernel mount-root namespaces differ" do
      with_namespace_mapped_probe do
        expect(backend.backing_storage_observation).to include(
          scope: "verified_docker_backing_store_probe", available_bytes: 90 * 1024)
      end
    end

    {
      "an unrelated bind source" => ->(info) { info["Mounts"].first["Source"] = "/unrelated/.paid-capacity-probe" },
      "a different bind target" => ->(info) { info["Mounts"].first["Destination"] = "/elsewhere" },
      "a writable bind" => ->(info) { info["Mounts"].first["RW"] = true },
      "a volume instead of a bind" => ->(info) { info["Mounts"].first["Type"] = "volume" },
      "malformed mount metadata" => ->(info) { info["Mounts"] = [ nil ] },
      "another container ID" => ->(info) { info["Id"] = "b" * 64 },
      "another container hostname" => ->(info) { info["Config"]["Hostname"] = "b" * 12 }
    }.each do |description, corrupt|
      # @spec CONTAINER-RUNTIME-055
      it "rejects #{description} across mount-root namespaces" do
        with_namespace_mapped_probe do |info|
          corrupt.call(info)

          expect(backend.backing_storage_observation).to eq(reason: "backing_storage_probe_unverified")
        end
      end
    end

    # @spec CONTAINER-RUNTIME-055
    it "refuses a writable kernel mount even when the daemon reports a read-only bind" do
      with_namespace_mapped_probe do |info|
        allow(File).to receive(:read).with("/proc/self/mountinfo")
          .and_return(mountinfo_for(root: "/docker/.paid-capacity-probe", target: info["Mounts"].first["Destination"], options: "rw"))

        expect(backend.backing_storage_observation).to eq(reason: "backing_storage_probe_unverified")
      end
    end

    # @spec CONTAINER-RUNTIME-055
    it "bounds a stalled daemon provenance inspection" do
      with_namespace_mapped_probe do
        stub_const("Containers::Backends::LocalDocker::BACKING_STORE_PROBE_TIMEOUT", 0.02)
        allow(Docker::Container).to receive(:get) { sleep 1 }
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        expect(backend.backing_storage_observation).to eq(reason: "backing_storage_probe_unavailable")
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.5
      end
    end

    # @spec CONTAINER-RUNTIME-055
    it "measures a probe whose mount metadata names the selected daemon root child" do
      with_backing_store_probe("#!/bin/sh\nprintf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev/test 100 10 90 10%% /mnt\\n'\n") do |probe_path|
        now = Time.zone.parse("2026-11-21 18:28:00 UTC")
        allow(File).to receive(:read).with("/proc/self/mountinfo").and_return(mountinfo_for(root: "/var/lib/docker/.paid-capacity-probe", target: probe_path))

        expect(backend.backing_storage_observation(now:)).to include(
          scope: "verified_docker_backing_store_probe",
          available_bytes: be_a(Integer),
          observed_at: now
        )
      end
    end

    # @spec CONTAINER-RUNTIME-055
    it "decodes an octal-escaped daemon root in kernel mount metadata" do
      with_backing_store_probe(
        "#!/bin/sh\nprintf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev/test 100 10 90 10%% /mnt\\n'\n",
        daemon_root: "/var/lib/docker root"
      ) do
        expect(backend.backing_storage_observation).to include(
          scope: "verified_docker_backing_store_probe",
          available_bytes: be_a(Integer)
        )
      end
    end

    # @spec CONTAINER-RUNTIME-055
    it "decodes an octal-escaped target for a probe path that actually contains a space" do
      with_backing_store_probe(
        "#!/bin/sh\nprintf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev/test 100 10 90 10%% /mnt\\n'\n",
        probe_directory_name: "probe path"
      ) do |probe_path|
        expect(probe_path).to include(" ")
        expect(backend.backing_storage_observation).to include(
          scope: "verified_docker_backing_store_probe",
          available_bytes: be_a(Integer)
        )
      end
    end

    # @spec CONTAINER-RUNTIME-055
    it "rejects an existing unrelated probe even when its configured root matches the selected daemon" do
      with_backing_store_probe("#!/bin/sh\nprintf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev/test 100 10 90 10%% /mnt\\n'\n") do |probe_path|
        allow(File).to receive(:read).with("/proc/self/mountinfo").and_return(mountinfo_for(root: "/unrelated/.paid-capacity-probe", target: probe_path))

        expect(backend.backing_storage_observation).to eq(reason: "backing_storage_probe_unverified")
      end
    end

    # @spec CONTAINER-RUNTIME-055
    it "rejects an existing configured probe without verified daemon provenance" do
      Dir.mktmpdir do |probe_path|
        original_path = ENV["PAID_DOCKER_BACKING_STORE_PROBE_PATH"]
        original_daemon_root = ENV["PAID_DOCKER_BACKING_STORE_DAEMON_ROOT"]
        ENV["PAID_DOCKER_BACKING_STORE_PROBE_PATH"] = probe_path
        ENV.delete("PAID_DOCKER_BACKING_STORE_DAEMON_ROOT")

        expect(backend.backing_storage_observation).to eq(reason: "backing_storage_probe_unverified")
      ensure
        ENV["PAID_DOCKER_BACKING_STORE_PROBE_PATH"] = original_path
        ENV["PAID_DOCKER_BACKING_STORE_DAEMON_ROOT"] = original_daemon_root
      end
    end

    # @spec CONTAINER-RUNTIME-055
    it "rejects a configured probe when it names a filesystem other than the selected daemon root" do
      with_backing_store_probe("#!/bin/sh\nprintf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev/test 100 10 90 10%% /mnt\\n'\n", daemon_root: "/srv/docker") do
        allow(Docker).to receive_messages(url: "unix:///var/run/docker.sock", info: { "DockerRootDir" => "/var/lib/docker" })

        expect(backend.backing_storage_observation).to eq(reason: "backing_storage_probe_wrong_filesystem")
      end
    end

    # @spec CONTAINER-RUNTIME-055
    it "rejects a configured probe for a remote Docker endpoint" do
      with_backing_store_probe("#!/bin/sh\nprintf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev/test 100 10 90 10%% /mnt\\n'") do
        allow(Docker).to receive(:url).and_return("tcp://another-host:2376")

        expect(backend.backing_storage_observation).to eq(reason: "backing_storage_probe_remote_mismatch")
      end
    end

    # @spec CONTAINER-RUNTIME-055
    it "terminates and reaps a hanging df probe within its deadline" do
      with_backing_store_probe("#!/bin/sh\nwhile :; do :; done\n") do
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        observation = backend.backing_storage_observation
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

        expect(observation).to eq(reason: "backing_storage_probe_unavailable")
        expect(elapsed).to be < described_class::BACKING_STORE_PROBE_TIMEOUT + 1.second
      end
    end

    # @spec CONTAINER-RUNTIME-055
    it "does not accept output from a probe that exits after its deadline" do
      with_backing_store_probe(<<~SH) do
          #!/bin/sh
          printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev/test 100 10 90 10%% /mnt\\n'
          exec 1>&-
          /bin/sleep 4
        SH

        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        observation = backend.backing_storage_observation
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

        expect(observation).to eq(reason: "backing_storage_probe_unavailable")
        expect(elapsed).to be < described_class::BACKING_STORE_PROBE_TIMEOUT + 1.second
      end
    end

    # @spec CONTAINER-RUNTIME-055
    it "treats malformed successful probe output as unavailable" do
      with_backing_store_probe("#!/bin/sh\nprintf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n'\n") do
        expect(backend.backing_storage_observation).to eq(reason: "backing_storage_probe_unavailable")
      end
    end

    # @spec CONTAINER-RUNTIME-055
    it "does not substitute the application container filesystem when no probe is configured" do
      allow(ENV).to receive(:[]).with("PAID_DOCKER_BACKING_STORE_PROBE_PATH").and_return(nil)

      expect(backend.backing_storage_observation).to eq(reason: "backing_storage_probe_unconfigured")
    end

    def mountinfo_for(root:, target:, options: "ro")
      "42 35 0:42 #{escape_mountinfo_path(root)} #{escape_mountinfo_path(target)} #{options} - ext4 /dev/test ro\n"
    end

    def escape_mountinfo_path(path)
      path.gsub(" ") { "\\040" }
    end
  end

  it "reports the local backend identifier" do
    expect(backend.identifier).to eq("local")
  end

  it "preserves a configured host identifier" do
    backend = described_class.new(identifier: "qnap")

    expect(backend.identifier).to eq("qnap")
    expect(backend.all_host_identifiers).to eq([ "qnap" ])
    expect(backend.container_host_for(container)).to eq("qnap")
  end

  it "delegates container creation and lookup to docker-api" do
    allow(Docker::Container).to receive(:create).and_return(container)
    allow(Docker::Container).to receive(:get).with("abc123").and_return(container)

    expect(backend.create_container("Image" => "paid-agent:latest")).to eq(container)
    expect(backend.get_container("abc123")).to eq(container)
  end

  # @spec LLM-ROUTING-013
  it "uses a scoped Docker transport deadline when creating a container" do
    connection = instance_double(Docker::Connection, url: "unix:///var/run/docker.sock", options: { read_timeout: 60 })
    timed_connection = instance_double(Docker::Connection)
    allow(Docker).to receive(:connection).and_return(connection)
    allow(Docker::Connection).to receive(:new)
      .with("unix:///var/run/docker.sock", { read_timeout: 60, timeout: 0.1, retry_limit: 0 })
      .and_return(timed_connection)
    allow(Docker::Container).to receive(:create).and_return(container)

    backend.create_container({ "Image" => "paid-agent:latest" }, deadline: 0.1)

    expect(Docker::Container).to have_received(:create).with({ "Image" => "paid-agent:latest" }, timed_connection)
  end

  # @spec LLM-ROUTING-013
  it "does not require a mutable connection when stopping without a deadline" do
    allow(container).to receive(:stop).with(timeout: 0)

    backend.stop_container(container, timeout: 0)

    expect(container).to have_received(:stop).with(timeout: 0)
  end

  it "routes upgraded stdin exec to the selected container" do
    input = StringIO.new("hello")
    allow(Containers::DockerExecWithStdin).to receive(:call).and_return([ [ "hello" ], [], 0 ])

    result = backend.exec_in_container_with_stdin(container, [ "cat" ], stdin: input, wait: 5)

    expect(result).to eq([ [ "hello" ], [], 0 ])
    expect(Containers::DockerExecWithStdin).to have_received(:call)
      .with(container:, command: [ "cat" ], stdin: input, wait: 5)
  end

  # @spec LLM-ROUTING-013
  it "passes the supplied deadline to the upgraded stdin exec sequence" do
    input = StringIO.new("hello")
    allow(Containers::DockerExecWithStdin).to receive(:call).and_return([ [], [], 0 ])

    backend.exec_in_container_with_stdin(container, [ "cat" ], stdin: input, wait: 5, deadline: 0.1)

    expect(Containers::DockerExecWithStdin).to have_received(:call)
      .with(container:, command: [ "cat" ], stdin: input, wait: 5, deadline: 0.1)
  end

  # @spec LLM-ROUTING-013
  it "scopes network lookup and creation to the supplied deadline" do
    connection = instance_double(Docker::Connection, url: "unix:///var/run/docker.sock", options: { read_timeout: 60 })
    timed_connection = instance_double(Docker::Connection)
    allow(Docker).to receive(:connection).and_return(connection)
    allow(Docker::Connection).to receive(:new)
      .with("unix:///var/run/docker.sock", { read_timeout: 60, timeout: 0.1, retry_limit: 0 })
      .and_return(timed_connection)
    allow(Docker::Network).to receive_messages(get: network, create: network)

    backend.get_network("paid_agent", deadline: 0.1)
    backend.create_network("paid_agent", { "Driver" => "bridge" }, deadline: 0.1)

    expect(Docker::Network).to have_received(:get).with("paid_agent", {}, timed_connection)
    expect(Docker::Network).to have_received(:create).with("paid_agent", { "Driver" => "bridge" }, timed_connection)
  end

  it "delegates network and volume access to docker-api" do
    allow(Docker::Network).to receive(:get).with("paid_agent").and_return(network)
    allow(Docker::Volume).to receive(:get).with("paid-workspace-1").and_return(volume)

    expect(backend.get_network("paid_agent")).to eq(network)
    expect(backend.get_volume("paid-workspace-1")).to eq(volume)
  end

  it "delegates volume deletion to docker-api" do
    allow(volume).to receive(:remove).with(force: true).and_return(true)

    expect(backend.delete_volume(volume, force: true)).to be(true)
  end

  it "accepts the legacy positional options hash when creating volumes" do
    allow(Docker::Volume).to receive(:create) do |name, options|
      expect(name).to eq("paid-workspace-1")
      expect(options).to eq("Labels" => { "paid.managed" => "true" })
      volume
    end

    expect(backend.create_volume("paid-workspace-1", "Labels" => { "paid.managed" => "true" })).to eq(volume)
  end

  it "builds an image from a Dockerfile string via docker-api's string-body build API" do
    built_image = instance_double(Docker::Image)
    allow(Docker::Image).to receive(:build).with("FROM scratch", { t: "paid-agent:go" }).and_return(built_image)

    expect(backend.build_image("FROM scratch", { t: "paid-agent:go" })).to eq(built_image)
  end

  it "bounds image build and deletion through a deadline-scoped connection" do
    timed_connection = instance_double(Docker::Connection)
    allow(Docker).to receive(:connection).and_return(connection = instance_double(Docker::Connection, url: "unix:///var/run/docker.sock", options: {}))
    allow(Docker::Connection).to receive(:new)
      .with("unix:///var/run/docker.sock", { timeout: 0.1, retry_limit: 0 })
      .and_return(timed_connection)
    allow(Docker::Image).to receive_messages(build: true, remove: true)

    backend.build_image("FROM scratch", { t: "paid-sdk-core-build" }, deadline: 0.1)
    backend.delete_image("paid-sdk-core-build", deadline: 0.1, force: true)

    expect(Docker::Image).to have_received(:build).with("FROM scratch", { t: "paid-sdk-core-build" }, timed_connection)
    expect(Docker::Image).to have_received(:remove).with("paid-sdk-core-build", { force: true }, timed_connection)
  end

  it "checks image usage via the ancestor container-list filter" do
    allow(Docker::Container).to receive(:all)
      .with(filters: { ancestor: [ "paid-agent:go-node" ] }.to_json)
      .and_return([ container ])

    expect(backend.image_in_use?("paid-agent:go-node")).to be(true)
  end
end
