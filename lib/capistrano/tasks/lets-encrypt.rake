require 'openssl'
require 'letsencrypt/cli/acme_wrapper'
require 'colorize'

namespace :lets_encrypt do

  desc 'Register Let\' Encrypt account with email'
  task :register do
    email = fetch(:lets_encrypt_email)
    if email.nil? || email == ""
      wrapper.log "no E-Mail specified!", :fatal
      exit 1
    end
    if !email[/.*@.*/]
      wrapper.log "not an email", :fatal
      exit 1
    end
    registration = client.register(contact: "mailto:" + email)
    registration.agree_terms
    wrapper.log "Account created, Terms accepted"
  end

  desc 'Check if the certificate are valid'
  task :check_certificate do
    on roles(fetch(:lets_encrypt_roles)) do
      check_certificate
    end
  end

  desc 'Authorize the domain using the ACME challenge'
  task :authorize do
    on roles(fetch(:lets_encrypt_roles), select: :primary) do
      unless check_certificate
        domains.each do |domain|
          authorize(domain)
        end
      end
    end
  end

  desc "create certificate and private key pair for domains. The first domain is the main CN domain"
  task :cert do
    cert(domains)
    on roles(fetch(:lets_encrypt_roles)) do
      domains.each do |domain|
        upload_certs domain
      end
    end
  end

  # On server methods

  def check_certificate
    if test("[ -f #{certificate_path} ]")
      temp_path = "/tmp/#{primary_domain}.cert.pem"
      download! certificate_path, temp_path
      wrapper.check_certificate(temp_path)
    else
      wrapper.log "No certificate found"
      false
    end
  end

  def authorize(domain)
    as_encrypt_user do
      wrapper.log "Authorizing #{domain.blue}."
      authorization = client.authorize(domain: domain)

      challenge = authorization.http01
      challenge_public_path = fetch(:lets_encrypt_challenge_public_path)
      challenge_path = File.join(challenge_public_path, File.dirname(challenge.filename))
      challenge_file_path = File.join(challenge_public_path, challenge.filename)
      execute :mkdir, '-pv', challenge_path

      wrapper.log "Writing challenge to #{challenge_file_path}", :debug

      execute :echo, "\"#{challenge.file_content}\" > #{challenge_file_path}"

      challenge.request_verification

      5.times do
        wrapper.log "Checking verification...", :debug
        sleep 1
        break if challenge.verify_status != 'pending'
      end
      if challenge.verify_status == 'valid'
        wrapper.log "Authorization successful for #{domain.green}"
        execute :rm, '-f', challenge_file_path
        true
      else
        wrapper.log "Authorization error for #{domain.red}", :error
        wrapper.log challenge.error['detail']
        false
      end
    end
  end

  def cert(domains)
    domains.each do |domain|
      FileUtils.mkdir_p(local_out_path(domain))
    end
    wrapper.cert(domains)
  end

  def upload_certs(domain)
    as_encrypt_user do
      execute :mkdir, '-pv', "#{fetch(:lets_encrypt_output_path)}/#{domain}"
      safe_upload! local_private_key_path, private_key_path
      safe_upload! local_fullchain_path, fullchain_path
      safe_upload! local_certificate_path, certificate_path
      safe_upload! local_chain_path, chain_path
    end
  end

  def as_encrypt_user(&block)
    if fetch(:lets_encrypt_user)
      as fetch(:lets_encrypt_user) do
        yield
      end
    else
      yield
    end
  end

  def safe_upload!(from, to)
    tempname = "/tmp/#{Time.now.to_f}"
    upload! from, tempname
    sudo :mv, tempname, to
  end

  # Helpers
  def certificate_path(domain = primary_domain)
    File.join(fetch(:lets_encrypt_output_path), domain, "cert.pem")
  end

  def chain_path(domain = primary_domain)
    File.join(fetch(:lets_encrypt_output_path), domain, "chain.pem")
  end

  def fullchain_path(domain = primary_domain)
    File.join(fetch(:lets_encrypt_output_path), domain, "fullchain.pem")
  end

  def private_key_path(domain = primary_domain)
    File.join(fetch(:lets_encrypt_output_path), domain, "key.pem")
  end

  def local_certificate_path(domain = primary_domain)
    File.join(local_out_path(domain), "cert.pem")
  end

  def local_chain_path(domain = primary_domain)
    File.join(local_out_path(domain), "chain.pem")
  end

  def local_fullchain_path(domain = primary_domain)
    File.join(local_out_path(domain), "fullchain.pem")
  end

  def local_private_key_path(domain = primary_domain)
    File.join(local_out_path(domain), "key.pem")
  end

  def local_out_path(domain = primary_domain)
    File.join(File.expand_path(fetch(:lets_encrypt_local_output_path)), domain)
  end

  def domains
    fetch(:lets_encrypt_domains).split(" ")
  end

  def primary_domain
    domains.first
  end

  def wrapper
    @wrapper ||= AcmeWrapper.new(options)
  end

  def options
    @options ||= {
      account_key: File.expand_path(fetch(:lets_encrypt_account_key)),
      test: fetch(:lets_encrypt_test),
      log_level: "info",
      color: true,
      days_valid: fetch(:lets_encrypt_days_valid),
      private_key_path: local_private_key_path,
      fullchain_path: local_fullchain_path,
      certificate_path: local_certificate_path,
      chain_path: local_chain_path,
    }
  end

  def client
    @client ||= wrapper.client
  end
end

namespace :load do
  task :defaults do
    set :lets_encrypt_roles,                 -> { :web }
    set :lets_encrypt_test,                  -> { false }
    set :lets_encrypt_email,                 -> { nil }
    set :lets_encrypt_domains,               -> { nil }
    set :lets_encrypt_challenge_public_path, -> { "#{release_path}/public" }
    set :lets_encrypt_output_path,           -> { "#{shared_path}/ssl/certs" }
    set :lets_encrypt_account_key,           -> { "#{fetch(:lets_encrypt_email)}.account_key.pem" }
    set :lets_encrypt_days_valid,            -> { 30 }
    set :lets_encrypt_local_output_path,     -> { "~/certs" }
  end
end
