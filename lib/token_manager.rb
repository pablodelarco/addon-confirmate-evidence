# =============================================================================
# TokenManager - OAuth2 token management for Clouditor API
# =============================================================================
# Obtains and caches bearer tokens via username/password authentication.
# Automatically refreshes tokens before expiry. Thread-safe.
#
# Part of addon-clouditor-evidence (EMERALD project)
# =============================================================================

require 'net/http'
require 'uri'
require 'json'
require 'base64'
require 'monitor'

# Manages OAuth2 bearer tokens for authenticating with the Clouditor API.
#
# Supports two modes:
#   1. Dynamic tokens via username/password authentication (recommended)
#   2. Static pre-configured token (for testing)
#
# Tokens are cached in memory and refreshed automatically when expired.
# All operations are thread-safe via Monitor mixin.
class TokenManager
  include MonitorMixin

  # Safety margin in seconds before actual token expiry to trigger refresh
  TOKEN_REFRESH_MARGIN = 30

  # @param config [Hash] parsed YAML configuration
  # @param logger [Logger] logger instance
  def initialize(config, logger)
    super() # Initialize MonitorMixin
    @config = config
    @logger = logger
    @token = nil
    @token_expiry = nil

    auth = config.dig('clouditor', 'auth') || {}
    @token_url = auth['token_url']
    @username = auth['username']
    @password = auth['password']
    @static_token = auth['static_token']
  end

  # Returns a valid bearer token, refreshing if necessary.
  #
  # @return [String] bearer token
  # @raise [RuntimeError] if token cannot be obtained
  def token
    synchronize do
      return @static_token if @static_token && !@static_token.empty?

      if @token.nil? || token_expired?
        refresh_token
      end

      @token
    end
  end

  private

  # Checks whether the cached token has expired or is about to expire.
  #
  # @return [Boolean] true if token should be refreshed
  def token_expired?
    return true if @token_expiry.nil?

    Time.now.to_i >= (@token_expiry - TOKEN_REFRESH_MARGIN)
  end

  # Obtains a new token from the Clouditor auth endpoint.
  #
  # @raise [RuntimeError] if authentication fails
  def refresh_token
    @logger.debug('TokenManager: refreshing bearer token')

    unless @token_url && @username && @password
      raise 'TokenManager: missing auth configuration (token_url, username, password)'
    end

    uri = URI.parse(@token_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 10
    http.read_timeout = 10

    request = Net::HTTP::Post.new(uri.path)
    request['Content-Type'] = 'application/json'
    request.body = JSON.generate({
      'username' => @username,
      'password' => @password
    })

    response = http.request(request)

    unless response.is_a?(Net::HTTPSuccess)
      raise "TokenManager: authentication failed (HTTP #{response.code}): #{response.body}"
    end

    data = JSON.parse(response.body)
    @token = data['token']

    unless @token && !@token.empty?
      raise "TokenManager: no token in auth response: #{response.body}"
    end

    # Extract expiry from JWT payload (without a JWT library)
    @token_expiry = extract_jwt_expiry(@token)

    @logger.info("TokenManager: token obtained, expires at #{Time.at(@token_expiry).utc}")
  rescue StandardError => e
    @logger.error("TokenManager: #{e.message}")
    raise
  end

  # Extracts the 'exp' claim from a JWT token by Base64-decoding the payload.
  # This avoids requiring an external JWT library.
  #
  # @param jwt [String] JWT token string
  # @return [Integer] expiry time as Unix timestamp
  def extract_jwt_expiry(jwt)
    parts = jwt.split('.')
    if parts.length < 2
      @logger.warn('TokenManager: token is not a valid JWT, defaulting to 1h expiry')
      return Time.now.to_i + 3600
    end

    # JWT Base64url decoding: replace URL-safe chars and pad
    payload_b64 = parts[1]
    payload_b64 = payload_b64.tr('-_', '+/')
    remainder = payload_b64.length % 4
    payload_b64 += '=' * (4 - remainder) if remainder > 0

    payload = JSON.parse(Base64.decode64(payload_b64))
    exp = payload['exp']

    if exp.nil?
      @logger.warn('TokenManager: no exp claim in JWT, defaulting to 1h expiry')
      return Time.now.to_i + 3600
    end

    exp.to_i
  rescue StandardError => e
    @logger.warn("TokenManager: failed to parse JWT expiry (#{e.message}), defaulting to 1h")
    Time.now.to_i + 3600
  end
end
