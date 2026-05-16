# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::TcpHealthProbe, :no_db do
  describe ".open?" do
    let(:container) { instance_double(Docker::Container) }

    it "uses a local socket for local backends" do
      backend = instance_double(Containers::Backends::Base, remote?: false)
      socket = instance_double(BasicSocket, close: nil)

      allow(Socket).to receive(:tcp).with("svc-host", 5432, connect_timeout: 1).and_return(socket)

      expect(described_class.open?(backend: backend, container: container, host: "svc-host", port: 5432)).to be(true)
    end

    it "execs a probe inside the container for remote backends" do
      backend = instance_double(Containers::Backends::Base, remote?: true)
      allow(backend).to receive(:exec_in_container).and_return([ [], [], 0 ])

      expect(described_class.open?(backend: backend, container: container, host: "svc-host", port: 5432)).to be(true)
      expect(backend).to have_received(:exec_in_container).with(
        container,
        [ "sh", "-c", a_string_including("127.0.0.1", "5432") ]
      )
    end

    it "returns false when the remote probe fails" do
      backend = instance_double(Containers::Backends::Base, remote?: true)
      allow(backend).to receive(:exec_in_container).and_return([ [], [ "connection refused" ], 1 ])

      expect(described_class.open?(backend: backend, container: container, host: "svc-host", port: 5432)).to be(false)
    end

    it "raises for an invalid remote probe port" do
      backend = instance_double(Containers::Backends::Base, remote?: true)

      expect {
        described_class.open?(backend: backend, container: container, host: "svc-host", port: "5432;rm -rf /")
      }.to raise_error(ArgumentError, 'Invalid probe port: "5432;rm -rf /"')
    end

    it "raises for an out-of-range remote probe port" do
      backend = instance_double(Containers::Backends::Base, remote?: true)

      expect {
        described_class.open?(backend: backend, container: container, host: "svc-host", port: 65_536)
      }.to raise_error(ArgumentError, "Invalid probe port: 65536")
    end
  end
end
