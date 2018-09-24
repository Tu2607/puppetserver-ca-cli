require 'puppetserver/ca/utils/cli_parsing'
require 'puppetserver/ca/host'
require 'puppetserver/ca/certificate_authority'
require 'puppetserver/ca/local_certificate_authority'
require 'puppetserver/ca/x509_loader'
require 'puppetserver/ca/config/puppet'
require 'puppetserver/ca/utils/file_system'
require 'puppetserver/ca/utils/signing_digest'
require 'puppetserver/ca/utils/config'

module Puppetserver
  module Ca
    module Action
      class Generate

        include Puppetserver::Ca::Utils

        # Only allow printing ascii characters, excluding /
        VALID_CERTNAME = /\A[ -.0-~]+\Z/
        CERTNAME_BLACKLIST = %w{--all --config}

        SUMMARY = "Generate a new certificate signed by the CA"
        BANNER = <<-BANNER
Usage:
  puppetserver ca generate [--help]
  puppetserver ca generate --certname NAME[,NAME] [--config PATH]
                           [--subject-alt-names NAME[,NAME]]
                           [--ca-client]

Description:
Generates a new certificate signed by the intermediate CA
and stores generated keys and certs on disk.

If the `--ca-client` flag is passed, the cert will be generated
offline, without using Puppet Server's signing code, and will add
a special extension authorizing it to talk to the CA API. This can
be used for regenerating the master's host cert, or for manually
setting up other nodes to be CA clients. Do not distribute certs
generated this way to any node that you do not intend to have
administrative access to the CA (e.g. the ability to sign a cert).

Since the `--ca-client` causes a cert to be generated offline, it
should ONLY be used when Puppet Server is NOT running, to avoid
conflicting with the actions of the CA service. This will be
mandatory in a future release.

To determine the target location, the default puppet.conf
is consulted for custom values. If using a custom puppet.conf
provide it with the --config flag

Options:
BANNER
        def initialize(logger)
          @logger = logger
        end

        def self.parser(parsed = {})
          parsed['certnames'] = []
          parsed['subject-alt-names'] = ''
          OptionParser.new do |opts|
            opts.banner = BANNER
            opts.on('--certname NAME[,NAME]', Array,
                 'One or more comma separated certnames') do |certs|
              parsed['certnames'] += certs
            end
            opts.on('--help', 'Display this generate specific help output') do |help|
              parsed['help'] = true
            end
            opts.on('--config CONF', 'Path to puppet.conf') do |conf|
              parsed['config'] = conf
            end
            opts.on('--subject-alt-names NAME[,NAME]',
                    'Subject alternative names for the generated cert') do |sans|
              parsed['subject-alt-names'] = sans
            end
            opts.on('--ca-client',
                    'Whether this cert will be used to request CA actions.\
                    Causes the cert to be generated offline.') do |ca_client|
              parsed['ca-client'] = true
            end
          end
        end

        def parse(args)
          results = {}
          parser = self.class.parser(results)

          errors = CliParsing.parse_with_errors(parser, args)

          if results['certnames'].empty?
            errors << '    At least one certname is required to generate'
          else
            results['certnames'].each do |certname|
              if CERTNAME_BLACKLIST.include?(certname)
                errors << "    Cannot manage cert named `#{certname}` from " +
                          "the CLI, if needed use the HTTP API directly"
              end

              if certname.match(/\p{Upper}/)
                errors << "    Certificate names must be lower case"
              end

              unless certname =~ VALID_CERTNAME
                errors << "  Certname #{certname} must not contain unprintable or non-ASCII characters"
              end
            end
          end

          errors_were_handled = CliParsing.handle_errors(@logger, errors, parser.help)

          exit_code = errors_were_handled ? 1 : nil

          return results, exit_code
        end

        def run(input)
          certnames = input['certnames']
          config_path = input['config']

          # Validate config_path provided
          if config_path
            errors = FileSystem.validate_file_paths(config_path)
            return 1 if CliParsing.handle_errors(@logger, errors)
          end

          # Load, resolve, and validate puppet config settings
          settings_overrides = {}
          puppet = Config::Puppet.new(config_path)
          puppet.load(settings_overrides)
          return 1 if CliParsing.handle_errors(@logger, puppet.errors)

          # We don't want generate to respect the alt names setting, since it is usually
          # used to generate certs for other nodes
          alt_names = input['subject-alt-names']

          # Load most secure signing digest we can for csr signing.
          signer = SigningDigest.new
          return 1 if CliParsing.handle_errors(@logger, signer.errors)

          # Generate and save certs and associated keys
          if input['ca-client']
            all_passed = generate_authorized_certs(certnames, alt_names, puppet.settings, signer.digest)
          else
            all_passed = generate_certs(certnames, alt_names, puppet.settings, signer.digest)
          end
          return all_passed ? 0 : 1
        end

        # Certs authorized to talk to the CA API need to be signed offline,
        # in order to securely add the special auth extension.
        def generate_authorized_certs(certnames, alt_names, settings, digest)
          # Make sure we have all the directories where we will be writing files
          FileSystem.ensure_dirs([settings[:ssldir],
                                  settings[:certdir],
                                  settings[:privatekeydir],
                                  settings[:publickeydir]])

          ca = Puppetserver::Ca::LocalCertificateAuthority.new(digest, settings)
          ca_cert, ca_key = ca.load_ca
          return false if CliParsing.handle_errors(@logger, ca.errors)

          passed = certnames.map do |certname|
            errors = check_for_existing_ssl_files(certname, settings)
            next false if CliParsing.handle_errors(@logger, errors)

            current_alt_names = process_alt_names(alt_names, certname)

            # For certs signed offline, any alt names are added directly to the cert,
            # rather than to the CSR.
            key, csr = generate_key_csr(certname, settings, digest)
            next false unless csr

            cert = ca.sign_authorized_cert(ca_key, ca_cert, csr, current_alt_names)
            next false unless save_file(cert.to_pem, certname, settings[:certdir], "Certificate")
            next false unless save_file(cert.to_pem, certname, settings[:signeddir], "Certificate")
            next false unless save_keys(certname, settings, key)
            ca.update_serial_file(cert.serial + 1)
            true
          end
          passed.all?
        end

        # Generate csrs and keys, then submit them to CA, request for the CA to sign
        # them, download the signed certificates from the CA, and finally save
        # the signed certs and associated keys. Returns true if all certs were
        # successfully created and saved.
        def generate_certs(certnames, alt_names, settings, digest)
          # Make sure we have all the directories where we will be writing files
          FileSystem.ensure_dirs([settings[:ssldir],
                                  settings[:certdir],
                                  settings[:privatekeydir],
                                  settings[:publickeydir]])

          ca = Puppetserver::Ca::CertificateAuthority.new(@logger, settings)

          passed = certnames.map do |certname|
            errors = check_for_existing_ssl_files(certname, settings)
            next false if CliParsing.handle_errors(@logger, errors)

            current_alt_names = process_alt_names(alt_names, certname)

            key, csr = generate_key_csr(certname, settings, digest, current_alt_names)
            next false unless csr
            next false unless ca.submit_certificate_request(certname, csr)
            next false unless ca.sign_certs([certname])
            if result = ca.get_certificate(certname)
              next false unless save_file(result.body, certname, settings[:certdir], "Certificate")
              next false unless save_keys(certname, settings, key)
              true
            else
              false
            end
          end
          passed.all?
        end

        # For certs signed offline, any alt names are added directly to the cert,
        # rather than to the CSR.
        def generate_key_csr(certname, settings, digest, alt_names = '')
          host = Puppetserver::Ca::Host.new(digest)
          private_key = host.create_private_key(settings[:keylength])
          extensions = []
          if !alt_names.empty?
            ef = OpenSSL::X509::ExtensionFactory.new
            extensions << ef.create_extension("subjectAltName",
                                              alt_names,
                                              false)
          end
          csr = host.create_csr(name: certname,
                                key: private_key,
                                cli_extensions: extensions,
                                csr_attributes_path: settings[:csr_attributes])
          return if CliParsing.handle_errors(@logger, host.errors)

          return private_key, csr
        end

        def save_keys(certname, settings, key)
          public_key = key.public_key
          return false unless save_file(key, certname, settings[:privatekeydir], "Private key")
          return false unless save_file(public_key, certname, settings[:publickeydir], "Public key")
          true
        end

        def save_file(content, certname, dir, type)
          location = File.join(dir, "#{certname}.pem")
          if File.exist?(location)
            @logger.err "#{type} #{certname}.pem already exists. Please delete it if you really want to regenerate it."
            false
          else
            FileSystem.write_file(location, content, 0640)
            @logger.inform "Successfully saved #{type.downcase} for #{certname} to #{location}"
            true
          end
        end

        def check_for_existing_ssl_files(certname, settings)
          files = [ File.join(settings[:certdir], "#{certname}.pem"),
                    File.join(settings[:privatekeydir], "#{certname}.pem"),
                    File.join(settings[:publickeydir], "#{certname}.pem"),
                    File.join(settings[:signeddir], "#{certname}.pem"), ]
          errors = Puppetserver::Ca::Utils::FileSystem.check_for_existing_files(files)
          if !errors.empty?
            errors << "Please delete these files if you really want to generate a new cert for #{certname}."
          end
          errors
        end

        def process_alt_names(alt_names, certname)
          return '' if alt_names.empty?

          current_alt_names = alt_names.dup
          # When validating the cert, OpenSSL will ignore the CN field if
          # altnames are present, so we need to ensure that the certname is
          # also listed among the alt names.
          current_alt_names += ",DNS:#{certname}"
          current_alt_names = Puppetserver::Ca::Utils::Config.munge_alt_names(current_alt_names)
        end
      end
    end
  end
end
