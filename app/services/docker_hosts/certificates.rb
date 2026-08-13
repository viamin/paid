# frozen_string_literal: true

require "ipaddr"
require "openssl"

module DockerHosts
  module Certificates
    module_function

    def build_certificate(subject:, issuer:, public_key:, signing_key:, serial:, is_ca:, san_entries: [], extended_key_usage: nil)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = serial
      cert.subject = OpenSSL::X509::Name.parse(subject)
      cert.issuer = issuer ? issuer.subject : cert.subject
      cert.public_key = public_key
      cert.not_before = Time.current
      cert.not_after = 365.days.from_now

      extension_factory = OpenSSL::X509::ExtensionFactory.new
      extension_factory.subject_certificate = cert
      extension_factory.issuer_certificate = issuer || cert
      cert.add_extension(extension_factory.create_extension("basicConstraints", is_ca ? "CA:TRUE" : "CA:FALSE", true))
      cert.add_extension(extension_factory.create_extension("keyUsage", is_ca ? "keyCertSign,cRLSign" : "digitalSignature,keyEncipherment", true))
      cert.add_extension(extension_factory.create_extension("subjectKeyIdentifier", "hash"))
      cert.add_extension(extension_factory.create_extension("authorityKeyIdentifier", "keyid:always,issuer:always"))
      cert.add_extension(extension_factory.create_extension("subjectAltName", san_entries.join(","))) if san_entries.any?
      cert.add_extension(extension_factory.create_extension("extendedKeyUsage", extended_key_usage)) if extended_key_usage.present?

      cert.sign(signing_key, OpenSSL::Digest::SHA256.new)
      cert
    end

    def build_certificate_request(subject:, private_key:, san_entries: [])
      request = OpenSSL::X509::Request.new
      request.version = 0
      request.subject = OpenSSL::X509::Name.parse(subject)
      request.public_key = private_key.public_key
      add_san_extensions!(request, san_entries)
      request.sign(private_key, OpenSSL::Digest::SHA256.new)
      request
    end

    def san_entries(raw_sans)
      raw_sans.to_s.split(/[\s,]+/).filter_map do |value|
        candidate = value.strip
        next if candidate.blank?

        if ip_address?(candidate)
          "IP:#{candidate}"
        else
          "DNS:#{candidate}"
        end
      end.uniq
    end

    def fingerprint(pem)
      return if pem.blank?

      OpenSSL::X509::Certificate.new(pem).fingerprint("SHA256")
    rescue OpenSSL::OpenSSLError
      nil
    end

    def ip_address?(value)
      IPAddr.new(value)
      true
    rescue IPAddr::InvalidAddressError
      false
    end

    def add_san_extensions!(request, san_entries)
      return if san_entries.empty?

      extension = OpenSSL::X509::ExtensionFactory.new.create_extension("subjectAltName", san_entries.join(","))
      request.add_attribute(
        OpenSSL::X509::Attribute.new(
          "extReq",
          OpenSSL::ASN1::Set([
            OpenSSL::ASN1::Sequence([
              OpenSSL::ASN1.decode(extension.to_der)
            ])
          ])
        )
      )
    end
  end
end
