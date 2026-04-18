# frozen_string_literal: true

require "rails_helper"

RSpec.describe Scaling::Orchestrator do
  let(:unimplemented_class) do
    Class.new do
      include Scaling::Orchestrator
    end
  end

  let(:unimplemented) { unimplemented_class.new }

  describe "the interface contract" do
    it "declares the capability methods scaling policy depends on" do
      expected_methods = %i[
        current_status
        scale
        set_resource_limits
        healthy?
      ]

      expect(described_class.instance_methods(false)).to include(*expected_methods)
    end

    it "raises NotImplementedError for each method when not overridden" do
      expect { unimplemented.current_status(service: "web") }
        .to raise_error(NotImplementedError, /#current_status/)
      expect { unimplemented.scale(service: "web", desired_replicas: 3) }
        .to raise_error(NotImplementedError, /#scale/)
      expect { unimplemented.set_resource_limits(service: "web", cpu_limit: "500m") }
        .to raise_error(NotImplementedError, /#set_resource_limits/)
      expect { unimplemented.healthy? }
        .to raise_error(NotImplementedError, /#healthy\?/)
    end

    it "provides an OrchestratorError base class for implementations to extend" do
      expect(described_class::OrchestratorError).to be < StandardError
    end
  end

  describe "a conforming implementation" do
    let(:implementation_class) do
      Class.new do
        include Scaling::Orchestrator

        def current_status(service:)
          Scaling::Orchestrators::Data::ServiceStatus.new(
            service: service,
            current_replicas: 2,
            desired_replicas: 2,
            available_replicas: 2,
            cpu_usage: nil,
            memory_usage: nil,
            ready: true
          )
        end

        def scale(service:, desired_replicas:)
          Scaling::Orchestrators::Data::ScaleResult.new(
            service: service,
            previous_replicas: 2,
            desired_replicas: desired_replicas,
            accepted: true,
            message: "scaled"
          )
        end

        def set_resource_limits(service:, cpu_limit: nil, memory_limit: nil)
          Scaling::Orchestrators::Data::ResourceUpdateResult.new(
            service: service,
            cpu_limit: cpu_limit,
            memory_limit: memory_limit,
            accepted: true,
            message: "updated"
          )
        end

        def healthy?
          true
        end
      end
    end

    it "can fulfill every interface method without raising" do
      impl = implementation_class.new

      expect(impl.current_status(service: "web"))
        .to be_a(Scaling::Orchestrators::Data::ServiceStatus)
      expect(impl.scale(service: "web", desired_replicas: 5))
        .to be_a(Scaling::Orchestrators::Data::ScaleResult)
      expect(impl.set_resource_limits(service: "web", cpu_limit: "500m"))
        .to be_a(Scaling::Orchestrators::Data::ResourceUpdateResult)
      expect(impl.healthy?).to be true
    end
  end
end
