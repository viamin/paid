# frozen_string_literal: true

require "fileutils"
require "openssl"
require "pathname"

module RemoteDockerCertHelper
  module_function

  def build_certificate(subject:, issuer:, public_key:, signing_key:, serial:, is_ca:, extended_key_usage: nil)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = serial
    cert.subject = OpenSSL::X509::Name.parse(subject)
    cert.issuer = issuer ? issuer.subject : cert.subject
    cert.public_key = public_key
    cert.not_before = Time.now
    cert.not_after = 365.days.from_now

    extension_factory = OpenSSL::X509::ExtensionFactory.new
    extension_factory.subject_certificate = cert
    extension_factory.issuer_certificate = issuer || cert
    cert.add_extension(extension_factory.create_extension("basicConstraints", is_ca ? "CA:TRUE" : "CA:FALSE", true))
    cert.add_extension(extension_factory.create_extension("keyUsage", is_ca ? "keyCertSign,cRLSign" : "digitalSignature,keyEncipherment", true))
    cert.add_extension(extension_factory.create_extension("subjectKeyIdentifier", "hash"))
    cert.add_extension(extension_factory.create_extension("authorityKeyIdentifier", "keyid:always,issuer:always"))
    if extended_key_usage
      cert.add_extension(extension_factory.create_extension("extendedKeyUsage", extended_key_usage))
    end

    cert.sign(signing_key, OpenSSL::Digest::SHA256.new)
    cert
  end

  def write_pem(path, contents, mode: 0o644)
    File.write(path, contents)
    File.chmod(mode, path)
  end
end

namespace :remote_docker do
  desc "Generate a CA and client certificate bundle for remote Docker mTLS"
  task :generate_certs, [ :output_dir, :common_name ] => :environment do |_task, args|
    output_dir = Pathname.new(args[:output_dir].presence || "tmp/remote-docker-certs")
    common_name = args[:common_name].presence || "paid-remote-docker-client"

    FileUtils.mkdir_p(output_dir)

    ca_key = OpenSSL::PKey::RSA.new(4096)
    ca_cert = RemoteDockerCertHelper.build_certificate(
      subject: "/CN=paid-remote-docker-ca",
      issuer: nil,
      public_key: ca_key.public_key,
      signing_key: ca_key,
      serial: 1,
      is_ca: true
    )

    client_key = OpenSSL::PKey::RSA.new(4096)
    client_cert = RemoteDockerCertHelper.build_certificate(
      subject: "/CN=#{common_name}",
      issuer: ca_cert,
      public_key: client_key.public_key,
      signing_key: ca_key,
      serial: 2,
      is_ca: false,
      extended_key_usage: "clientAuth"
    )

    RemoteDockerCertHelper.write_pem(output_dir.join("ca.pem"), ca_cert.to_pem)
    RemoteDockerCertHelper.write_pem(output_dir.join("ca-key.pem"), ca_key.to_pem, mode: 0o600)
    RemoteDockerCertHelper.write_pem(output_dir.join("client-cert.pem"), client_cert.to_pem)
    RemoteDockerCertHelper.write_pem(output_dir.join("client-key.pem"), client_key.to_pem, mode: 0o600)

    puts "Generated remote Docker TLS assets in #{output_dir}"
    puts "Use these env vars:"
    puts "  REMOTE_DOCKER_CERT=#{output_dir.join('client-cert.pem')}"
    puts "  REMOTE_DOCKER_KEY=#{output_dir.join('client-key.pem')}"
    puts "  REMOTE_DOCKER_CA=#{output_dir.join('ca.pem')}"
    puts "Install ca.pem on the remote Docker host and sign or trust the server certificate separately."
  end

  desc "Ping the configured remote Docker backend over TCP+TLS"
  task test_connection: :environment do
    backend = Containers::Backends::RemoteDocker.from_env
    raise "REMOTE_DOCKER_HOST is not configured" unless backend

    response = backend.ping
    puts "Remote backend #{backend.identifier} responded with #{response.inspect}"
  end
end
