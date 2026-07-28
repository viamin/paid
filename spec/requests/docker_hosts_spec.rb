# frozen_string_literal: true

require "rails_helper"

RSpec.describe "DockerHosts", type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account: account) }

  before do
    create(:tenant_setting, account: account)
    sign_in user
  end

  it "ignores readiness fields on create" do
    post docker_hosts_path, params: { docker_host: docker_host_params }

    host = account.docker_hosts.find_by!(identifier: "edge-builder")

    expect(response).to redirect_to(setup_docker_host_path(host))
    expect_readiness_fields_to_remain_system_managed(host)
  end

  it "ignores readiness fields on update" do
    host = create(:docker_host, account: account, readiness_status: "failing", failing_check: "image")

    patch docker_host_path(host), params: {
      docker_host: {
        display_name: "Updated Host",
        readiness_status: "ready",
        failing_check: "spoofed",
        daemon_summary: "Spoofed daemon"
      }
    }

    expect(response).to redirect_to(docker_host_path(host))

    host.reload
    expect(host.display_name).to eq("Updated Host")
    expect(host.readiness_status).to eq("failing")
    expect(host.failing_check).to eq("image")
    expect(host.daemon_summary).not_to eq("Spoofed daemon")
  end

  it "keeps identifiers unchanged on update" do
    host = create(:docker_host, account: account, identifier: "edge-builder")

    patch docker_host_path(host), params: {
      docker_host: {
        identifier: "renamed-host",
        display_name: "Updated Host"
      }
    }

    expect(response).to redirect_to(docker_host_path(host))

    host.reload
    expect(host.identifier).to eq("edge-builder")
    expect(host.display_name).to eq("Updated Host")
  end

  it "clears saved account and project preferences when a host is disabled via the disable action" do
    host = create(:docker_host, account: account, identifier: "elguapo")
    tenant_setting = account.tenant_setting || create(:tenant_setting, account: account)
    project = create(:project, account: account, created_by: user, preferred_docker_host_identifier: "elguapo")
    tenant_setting.update!(preferred_docker_host_identifier: "elguapo")

    patch disable_docker_host_path(host)

    expect(response).to redirect_to(docker_host_path(host))
    expect(host.reload).to be_disabled
    expect(tenant_setting.reload.preferred_docker_host_identifier).to be_nil
    expect(project.reload.preferred_docker_host_identifier).to be_nil
  end

  it "clears saved account and project preferences when a host is disabled via the update form" do
    host = create(:docker_host, account: account, identifier: "formpath")
    tenant_setting = account.tenant_setting || create(:tenant_setting, account: account)
    project = create(:project, account: account, created_by: user, preferred_docker_host_identifier: "formpath")
    tenant_setting.update!(preferred_docker_host_identifier: "formpath")

    patch docker_host_path(host), params: { docker_host: { display_name: host.display_name, enabled: "0" } }

    expect(response).to redirect_to(docker_host_path(host))
    expect(host.reload).to be_disabled
    expect(tenant_setting.reload.preferred_docker_host_identifier).to be_nil
    expect(project.reload.preferred_docker_host_identifier).to be_nil
  end

  it "persists setup guide fields and profile state per host" do
    host = create(:docker_host, account: account, required_network_name: "paid-agents")

    patch setup_docker_host_path(host), params: {
      setup_profile: "qnap_nas",
      docker_host: {
        display_name: "QNAP Edge",
        callback_url: "https://paid.example.test/health/services",
        required_network_name: "shared-agents",
        manual_concurrency_limit: 6
      }
    }

    expect(response).to redirect_to(setup_docker_host_path(host))

    host.reload
    expect(host.display_name).to eq("QNAP Edge")
    expect(host.required_network_name).to eq("shared-agents")
    expect(host.manual_concurrency_limit).to eq(6)
    expect(host.setup_profile).to eq("qnap_nas")
  end

  def docker_host_params
    {
      display_name: "Edge Builder",
      identifier: "edge-builder",
      backend_type: "remote",
      endpoint: "tcp://docker.example.test:2376",
      callback_url: "https://paid.example.test/health/services",
      image_tag: "paid-agent:stable",
      fallback_eligible: "1",
      manual_concurrency_limit: "3",
      enabled: "1",
      readiness_status: "ready",
      failing_check: "spoofed",
      last_checked_at: 1.day.ago.iso8601,
      last_ready_at: Time.current.iso8601,
      last_error: "spoofed error",
      daemon_architecture: "arm64",
      daemon_summary: "Docker 99.9",
      image_status: "ready",
      required_network_status: "ready"
    }
  end

  def expect_readiness_fields_to_remain_system_managed(host)
    expect(host.readiness_status).to eq("unknown")
    expect(host.failing_check).to be_nil
    expect(host.last_checked_at).to be_nil
    expect(host.last_ready_at).to be_nil
    expect(host.last_error).to be_nil
    expect(host.daemon_architecture).to be_nil
    expect(host.daemon_summary).to be_nil
    expect(host.image_status).to eq("unknown")
    expect(host.required_network_status).to eq("unknown")
  end
end
