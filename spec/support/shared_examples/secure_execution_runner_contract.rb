# frozen_string_literal: true

# Shared examples for security-sensitive runner behavior. Including specs supply
# runner-specific setup/stubs while the assertions stay at the provider-neutral
# boundary.
#
# Expected `let` bindings:
#
#   runner                         — concrete runner instance
#   secure_run_spec        — restricted-mode RunSpec carrying any secret config under test
#   second_secure_run_spec — same as secure_run_spec but for a second AgentRun
RSpec.shared_examples "a secure execution runner" do
  let(:secret_values_excluded_from_handle_metadata) { [] }
  let(:expected_proxy_scope_agent_run_ids) { nil }
  let(:captured_proxy_scope_credentials) { nil }
  let(:expects_secure_firewall_rules) { true }

  it "restricted mode blocks non-allowed traffic" do
    handle = runner.provision(spec: secure_run_spec)

    expect(handle).to be_a(ExecutionRunners::RunnerHandle)
    expect(NetworkPolicy).to have_received(:apply_firewall_rules) if expects_secure_firewall_rules
  end

  it "keeps secrets out of the persisted handle environment" do
    handle = runner.provision(spec: secure_run_spec)

    expect(handle).to be_a(ExecutionRunners::RunnerHandle)
    expect(NetworkPolicy).to have_received(:apply_firewall_rules) if expects_secure_firewall_rules
    secret_values_excluded_from_handle_metadata.each do |secret|
      expect(handle.metadata.to_json).not_to include(secret)
    end
  end

  it "scopes any proxy-backed credentials to the run" do
    first_handle = runner.provision(spec: secure_run_spec)
    second_handle = runner.provision(spec: second_secure_run_spec)

    expect(first_handle).to be_a(ExecutionRunners::RunnerHandle)
    expect(second_handle).to be_a(ExecutionRunners::RunnerHandle)
    if expected_proxy_scope_agent_run_ids
      expect(first_handle.metadata["agent_run_id"]).to eq(expected_proxy_scope_agent_run_ids.fetch(0))
      expect(second_handle.metadata["agent_run_id"]).to eq(expected_proxy_scope_agent_run_ids.fetch(1))
    end
    expect(first_handle.metadata["agent_run_id"]).not_to eq(second_handle.metadata["agent_run_id"])

    next unless captured_proxy_scope_credentials

    expect(captured_proxy_scope_credentials.fetch(0)).to include(
      agent_run_id: secure_run_spec.agent_run.id,
      proxy_token: secure_run_spec.agent_run.proxy_token
    )
    expect(captured_proxy_scope_credentials.fetch(1)).to include(
      agent_run_id: second_secure_run_spec.agent_run.id,
      proxy_token: second_secure_run_spec.agent_run.proxy_token
    )
    expect(captured_proxy_scope_credentials.fetch(0)[:proxy_token])
      .not_to eq(captured_proxy_scope_credentials.fetch(1)[:proxy_token])
  end
end
