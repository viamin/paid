# frozen_string_literal: true
=begin
= Info
  'OpenSSL for Ruby 2' project
  Copyright (C) 2002  Michal Rokos <m.rokos@sh.cvut.cz>
  All rights reserved.

= Licence
  This program is licensed under the same licence as Ruby.
  (See the file 'LICENCE'.)
=end

# Fall back to bundled CA certificates only when no system certs exist.
# System cert auto-detection is handled at the C level in portable-openssl;
# this only activates for minimal environments (e.g. containers without ca-certificates).
if ENV["SSL_CERT_FILE"].to_s.empty?
  system_certs = %w[
    /etc/ssl/certs/ca-certificates.crt
    /etc/pki/tls/certs/ca-bundle.crt
    /etc/ssl/ca-bundle.pem
    /etc/ssl/cert.pem
  ]
  unless system_certs.any? { |f| File.exist?(f) }
    bundled = File.expand_path("../../libexec/cert.pem", RbConfig.ruby)
    ENV["SSL_CERT_FILE"] = bundled if File.exist?(bundled)
  end
end
require 'openssl.so'

require_relative 'openssl/bn'
require_relative 'openssl/pkey'
require_relative 'openssl/cipher'
require_relative 'openssl/digest'
require_relative 'openssl/hmac'
require_relative 'openssl/x509'
require_relative 'openssl/ssl'
require_relative 'openssl/pkcs5'
require_relative 'openssl/version'

module OpenSSL
  # call-seq:
  #   OpenSSL.secure_compare(string, string) -> boolean
  #
  # Constant time memory comparison. Inputs are hashed using SHA-256 to mask
  # the length of the secret. Returns +true+ if the strings are identical,
  # +false+ otherwise.
  def self.secure_compare(a, b)
    hashed_a = OpenSSL::Digest.digest('SHA256', a)
    hashed_b = OpenSSL::Digest.digest('SHA256', b)
    OpenSSL.fixed_length_secure_compare(hashed_a, hashed_b) && a == b
  end
end
