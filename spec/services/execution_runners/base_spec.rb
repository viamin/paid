# frozen_string_literal: true

require "rails_helper"

# @spec CONTAINER-RUNTIME-007
RSpec.describe ExecutionRunners::Base do
  let(:spec) do
    ExecutionRunners::RunSpec.new(
      agent_run: nil, project: nil, image: "img", command: "cmd", resources: nil,
      environment: {}, networking_policy: nil,
      workspace: ExecutionRunners::WorkspaceStrategy.ephemeral,
      services: [], secrets_config: nil, preview_tunnel: nil
    )
  end
  let(:handle) do
    ExecutionRunners::RunnerHandle.new(runner_type: :local_docker, identifier: "id",
                                       host: "local", workspace_ref: "vol", metadata: {})
  end

  describe "abstract instance methods" do
    it "raises NotImplementedError for #provision" do
      expect { described_class.new.provision(spec: spec) }
        .to raise_error(NotImplementedError, /provision/)
    end

    it "raises NotImplementedError for #start" do
      expect do
        described_class.new.start(handle: handle, command: "cmd", timeout: 60,
                                  startup_timeout: 30, idle_timeout: 30,
                                  abort_patterns: nil, preparation: nil, heartbeat_path: nil)
      end.to raise_error(NotImplementedError, /start/)
    end

    it "raises NotImplementedError for #status" do
      expect { described_class.new.status(handle: handle) }
        .to raise_error(NotImplementedError, /status/)
    end

    it "raises NotImplementedError for #running?" do
      expect { described_class.new.running?(handle: handle) }
        .to raise_error(NotImplementedError, /running/)
    end

    it "raises NotImplementedError for #cancel" do
      expect { described_class.new.cancel(handle: handle) }
        .to raise_error(NotImplementedError, /cancel/)
    end

    it "raises NotImplementedError for #cleanup" do
      expect { described_class.new.cleanup(handle: handle, force: true) }
        .to raise_error(NotImplementedError, /cleanup/)
    end
  end

  describe "abstract class methods" do
    it "raises NotImplementedError for .compatible?" do
      expect { described_class.compatible?(spec: spec, backend: instance_double(Containers::Backends::Base)) }
        .to raise_error(NotImplementedError, /compatible/)
    end

    it "raises NotImplementedError for .ping" do
      expect { described_class.ping }.to raise_error(NotImplementedError, /ping/)
    end
  end

  describe "interface neutrality" do
    it "exposes only the domain lifecycle methods, none referencing Docker concepts" do
      instance_methods = described_class.instance_methods(false)

      expect(instance_methods).to contain_exactly(:provision, :start, :running?, :status, :cancel, :cleanup)

      forbidden = %w[docker container_id bind_mount exec_in_container network_name]
      instance_methods.each do |method|
        expect(method.to_s).not_to match(/#{forbidden.join("|")}/)
      end
    end
  end
end
