# =============================================================================
# ConfirmateClient - HTTP client for the Confirmate Evidence Store API
# =============================================================================
# Sends evidence payloads to the Confirmate Evidence Store via REST API.
# Handles authentication, retries with exponential backoff, and logging.
#
# Part of addon-confirmate-evidence (EMERALD project)
# =============================================================================

require 'net/http'
require 'uri'
require 'json'
require 'logger'
require 'yaml'

$LOAD_PATH.unshift(File.dirname(__FILE__)) unless $LOAD_PATH.include?(File.dirname(__FILE__))
require 'token_manager'

# HTTP client for posting evidence to the Confirmate Evidence Store.
#
# Uses TokenManager for automatic bearer token management and implements
# retry logic with exponential backoff for transient failures.
class ConfirmateClient
  # Maximum number of retry attempts for failed requests
  MAX_RETRIES = 3

  # Base delay in seconds for exponential backoff
  BASE_DELAY = 1

  # Evidence Store REST endpoint path (unchanged between Clouditor and Confirmate)
  EVIDENCE_PATH = '/v1/evidence_store/evidence'

  # @param config [Hash] parsed YAML configuration
  # @param logger [Logger, nil] optional logger (creates default if nil)
  def initialize(config, logger = nil)
    @config = config
    @logger = logger || create_logger(config)
    @endpoint = config.dig('confirmate', 'endpoint') || 'http://localhost:8080'
    @token_manager = TokenManager.new(config, @logger)
  end

  # Sends an evidence payload to the Clouditor Evidence Store.
  #
  # @param evidence [Hash] evidence payload (as returned by OntologyMapper)
  # @return [Hash] parsed response body on success
  # @raise [RuntimeError] if all retries are exhausted
  def store_evidence(evidence)
    evidence_id = evidence.dig('evidence', 'id') || 'unknown'
    resource_type = evidence.dig('evidence', 'resource')&.keys&.first || 'unknown'
    resource_id = evidence.dig('evidence', 'resource', resource_type, 'id') || 'unknown'

    @logger.info("Sending evidence #{evidence_id} (#{resource_type}: #{resource_id})")
    @logger.debug("Evidence payload: #{JSON.generate(evidence)}")

    attempt = 0
    last_error = nil

    while attempt < MAX_RETRIES
      attempt += 1

      begin
        response = post_evidence(evidence)

        case response
        when Net::HTTPSuccess
          @logger.info("Evidence #{evidence_id} stored successfully (HTTP #{response.code})")
          return JSON.parse(response.body) rescue {}
        when Net::HTTPUnauthorized
          @logger.warn("Token expired, refreshing and retrying (attempt #{attempt}/#{MAX_RETRIES})")
          @token_manager = TokenManager.new(@config, @logger)
        else
          @logger.warn("HTTP #{response.code} from Evidence Store (attempt #{attempt}/#{MAX_RETRIES}): #{response.body}")
        end
      rescue StandardError => e
        last_error = e
        @logger.warn("Request failed (attempt #{attempt}/#{MAX_RETRIES}): #{e.message}")
      end

      if attempt < MAX_RETRIES
        delay = BASE_DELAY * (2**(attempt - 1))
        @logger.debug("Retrying in #{delay}s...")
        sleep(delay)
      end
    end

    error_msg = "Failed to store evidence #{evidence_id} after #{MAX_RETRIES} attempts"
    error_msg += ": #{last_error.message}" if last_error
    @logger.error(error_msg)
    raise error_msg
  end

  private

  # Performs the HTTP POST to the Evidence Store.
  #
  # @param evidence [Hash] evidence payload
  # @return [Net::HTTPResponse]
  def post_evidence(evidence)
    uri = URI.parse("#{@endpoint}#{EVIDENCE_PATH}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 10
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri.path)
    request['Content-Type'] = 'application/json'
    token = @token_manager.token
    request['Authorization'] = "Bearer #{token}" if token
    request.body = JSON.generate(evidence)

    http.request(request)
  end

  # Creates a logger instance from configuration.
  #
  # @param config [Hash] parsed YAML configuration
  # @return [Logger]
  def create_logger(config)
    log_file = config.dig('logging', 'file') || $stderr
    log_level = config.dig('logging', 'level') || 'info'

    logger = if log_file.is_a?(String)
               begin
                 Logger.new(log_file, 10, 1_048_576) # 10 rotated files, 1MB each
               rescue StandardError
                 Logger.new($stderr)
               end
             else
               Logger.new(log_file)
             end

    logger.level = case log_level.downcase
                   when 'debug' then Logger::DEBUG
                   when 'info'  then Logger::INFO
                   when 'warn'  then Logger::WARN
                   when 'error' then Logger::ERROR
                   else Logger::INFO
                   end

    logger.formatter = proc do |severity, datetime, _progname, msg|
      "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] #{severity} confirmate-evidence: #{msg}\n"
    end

    logger
  end
end
