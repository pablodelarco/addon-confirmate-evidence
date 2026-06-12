#!/usr/bin/ruby
# =============================================================================
# Smoke test: end-to-end against a local Confirmate orchestrator
# =============================================================================
# Maps the VM XML fixture through OntologyMapper and POSTs the resulting
# Evidence to Confirmate's StoreEvidence endpoint, asserting that the
# orchestrator accepts the payload.
#
# Usage:
#   1. Start the Confirmate all-in-one server:
#        cd /path/to/confirmate/core
#        go build -o bin/confirmate ./cmd/confirmate
#        ./bin/confirmate --db-in-memory --create-default-target-of-evaluation
#                         [--auth-enabled --oauth2-embedded --oauth2-key-save-on-create]
#      Listens on http://localhost:8080 by default. With
#      --create-default-target-of-evaluation, the default ToE UUID is
#      00000000-0000-0000-0000-000000000000.
#
#   2. Run the smoke test:
#      Auth off (simplest):
#        CONFIRMATE_URL=http://localhost:8080 ruby tests/smoke.rb
#
#      Auth on (OAuth2 client_credentials):
#        CONFIRMATE_URL=http://localhost:8080  \
#        CONFIRMATE_AUTH=on                    \
#        CONFIRMATE_CLIENT_ID=confirmate       \
#        CONFIRMATE_CLIENT_SECRET=confirmate   \
#          ruby tests/smoke.rb
#
# Env vars:
#   CONFIRMATE_URL          — required-ish; default http://localhost:8080
#   TOE_ID                  — default 00000000-0000-0000-0000-000000000000
#   CONFIRMATE_AUTH         — "on" / "true" / "1" to enable bearer auth
#   CONFIRMATE_CLIENT_ID    — default "confirmate"
#   CONFIRMATE_CLIENT_SECRET — default "confirmate"
#
# If CONFIRMATE_URL is unreachable, the test skips rather than fails —
# making it CI-safe.
# =============================================================================

require 'logger'
require 'json'
require 'net/http'
require 'uri'

$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))
require 'ontology_mapper'
require 'confirmate_client'

CONFIRMATE_URL = ENV['CONFIRMATE_URL'] || 'http://localhost:8080'
TOE_ID         = ENV['TOE_ID']         || '00000000-0000-0000-0000-000000000000'
AUTH_ENABLED   = %w[1 true yes on].include?((ENV['CONFIRMATE_AUTH'] || '').downcase)
CLIENT_ID      = ENV['CONFIRMATE_CLIENT_ID']     || 'confirmate'
CLIENT_SECRET  = ENV['CONFIRMATE_CLIENT_SECRET'] || 'confirmate'

logger = Logger.new($stdout)
logger.level = Logger::INFO

# Quick reachability probe — skip gracefully if no orchestrator is running.
begin
  uri = URI.parse(CONFIRMATE_URL)
  http = Net::HTTP.new(uri.host, uri.port)
  http.open_timeout = 2
  http.read_timeout = 2
  http.start { http.request(Net::HTTP::Get.new('/')) }
rescue StandardError => e
  warn "SKIP: Confirmate orchestrator not reachable at #{CONFIRMATE_URL} (#{e.message})."
  warn '     Start one with the README "Appendix A" recipe:'
  warn '     go build -o bin/orchestrator ./cmd/orchestrator && ./bin/orchestrator --db-in-memory --create-default-target-of-evaluation'
  exit 0
end

config = {
  'confirmate' => {
    'endpoint' => CONFIRMATE_URL,
    'auth' => {
      'enabled'       => AUTH_ENABLED,
      'token_url'     => "#{CONFIRMATE_URL}/v1/auth/token",
      'client_id'     => CLIENT_ID,
      'client_secret' => CLIENT_SECRET
    }
  },
  'evidence' => {
    'tool_id' => 'opennebula-addon-confirmate-evidence-smoketest',
    'target_of_evaluation_id' => TOE_ID,
    'default_region' => 'eu-south-1'
  },
  'logging' => { 'level' => 'info', 'file' => '/dev/stdout' }
}

xml = File.read(File.join(File.dirname(__FILE__), 'fixtures', 'vm_template.xml'))

mapper   = OntologyMapper.new(config)
evidence = mapper.map_vm(xml)

logger.info "Submitting evidence: id=#{evidence['id']} toolId=#{evidence['toolId']}"
logger.info "Resource: #{evidence['resource'].keys.first} = #{evidence['resource'].values.first['id']}"

client = ConfirmateClient.new(config, logger)
client.store_evidence(evidence)

logger.info 'PASS — Confirmate accepted the evidence.'
