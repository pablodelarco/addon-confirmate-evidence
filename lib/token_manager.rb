# =============================================================================
# TokenManager - OAuth2 token management for Confirmate API
# =============================================================================
# Obtains and caches bearer tokens via the OAuth 2.0 client_credentials
# grant against an OpenID Connect provider. In production (EMERALD Pilot 4)
# this is Keycloak; for local testing it is Confirmate's embedded OAuth
# server. Any RFC 6749 compatible token endpoint works.
# Automatically refreshes tokens before expiry. Thread-safe.
#
# Part of addon-confirmate-evidence (EMERALD project)
# =============================================================================

require 'net/http'
require 'openssl'
require 'uri'
require 'json'
require 'base64'
require 'monitor'

# Manages bearer tokens for authenticating with the Confirmate API.
#
# Three modes:
#   1. Disabled (auth.enabled = false)         -> #token returns nil; the
#      ConfirmateClient must skip the Authorization header.
#   2. Static token (auth.static_token = "..") -> returned verbatim.
#   3. Dynamic OAuth 2.0 client_credentials    -> POST to auth.token_url
#      with HTTP Basic (client_id:client_secret); reads access_token and
#      expires_in from the standard OAuth2 response.
#
# Tokens are cached in memory and refreshed `TOKEN_REFRESH_MARGIN` seconds
# before expiry. All operations are thread-safe via Monitor mixin.
class TokenManager
  include MonitorMixin

  # Safety margin in seconds before actual token expiry to trigger refresh
  TOKEN_REFRESH_MARGIN = 30

  # Fallback lifetime if the OAuth server omits expires_in
  DEFAULT_TOKEN_LIFETIME = 3600

  # @param config [Hash] parsed YAML configuration
  # @param logger [Logger] logger instance
  def initialize(config, logger)
    super() # Initialize MonitorMixin
    @config = config
    @logger = logger
    @token = nil
    @token_expiry = nil

    auth = config.dig('confirmate', 'auth') || {}
    @enabled = auth.fetch('enabled', false)
    @token_url = auth['token_url']
    @client_id = auth['client_id']
    @client_secret = auth['client_secret']
    @static_token = auth['static_token']
    @ca_file = config.dig('confirmate', 'tls', 'ca_file')
  end

  # Returns a valid bearer token, refreshing if necessary.
  # Returns nil when authentication is disabled in config — callers must
  # treat that as "do not send an Authorization header".
  #
  # @return [String, nil] bearer token, or nil when auth is disabled
  # @raise [RuntimeError] if a token is required but cannot be obtained
  def token
    synchronize do
      return nil unless @enabled
      return @static_token if @static_token && !@static_token.empty?

      refresh_token if @token.nil? || token_expired?
      @token
    end
  end

  private

  # Checks whether the cached token has expired or is about to expire.
  def token_expired?
    return true if @token_expiry.nil?

    Time.now.to_i >= (@token_expiry - TOKEN_REFRESH_MARGIN)
  end

  # Obtains a new token from the Confirmate auth endpoint via the OAuth 2.0
  # client_credentials grant. Sends client_id / client_secret as HTTP Basic
  # auth and `grant_type=client_credentials` as a form-encoded body.
  #
  # @raise [RuntimeError] if authentication fails
  def refresh_token
    @logger.debug('TokenManager: requesting OAuth2 client_credentials token')

    unless @token_url && @client_id && @client_secret
      raise 'TokenManager: missing auth configuration ' \
            '(confirmate.auth.token_url, client_id, client_secret)'
    end

    uri = URI.parse(@token_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    apply_ca_file(http)
    http.open_timeout = 10
    http.read_timeout = 10

    request_path = uri.path.empty? ? '/' : uri.path
    request_path = "#{request_path}?#{uri.query}" if uri.query
    request = Net::HTTP::Post.new(request_path)
    request['Content-Type'] = 'application/x-www-form-urlencoded'
    request['Accept'] = 'application/json'
    request.basic_auth(@client_id, @client_secret)
    request.body = 'grant_type=client_credentials'

    response = http.request(request)

    unless response.is_a?(Net::HTTPSuccess)
      raise "TokenManager: token request failed (HTTP #{response.code}): #{response.body}"
    end

    data = JSON.parse(response.body)
    @token = data['access_token']

    unless @token && !@token.empty?
      raise "TokenManager: no access_token in OAuth response: #{response.body}"
    end

    expires_in = data['expires_in']&.to_i
    expires_in = DEFAULT_TOKEN_LIFETIME if expires_in.nil? || expires_in <= 0
    @token_expiry = Time.now.to_i + expires_in

    @logger.info("TokenManager: token obtained, expires at #{Time.at(@token_expiry).utc} " \
                 "(expires_in=#{expires_in}s)")
  rescue StandardError => e
    @logger.error("TokenManager: #{e.message}")
    raise
  end

  # When confirmate.tls.ca_file is configured, trust that CA bundle IN ADDITION
  # to the host's system roots, so the token request to an HTTPS IdP (Keycloak)
  # succeeds on hosts whose default trust store lacks the signing CA.
  # Certificate verification (VERIFY_PEER) is never weakened.
  def apply_ca_file(http)
    return unless http.use_ssl? && @ca_file && !@ca_file.empty?

    store = OpenSSL::X509::Store.new
    store.set_default_paths
    store.add_file(@ca_file)
    http.cert_store = store
  end
end
