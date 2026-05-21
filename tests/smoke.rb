#!/usr/bin/ruby
# =============================================================================
# Smoke test: end-to-end against a local Confirmate orchestrator
# =============================================================================
# Maps the VM XML fixture through OntologyMapper and POSTs the resulting
# Evidence to Confirmate's StoreEvidence endpoint, asserting that the
# orchestrator accepts the payload.
#
# Usage:
#   1. Start Confirmate orchestrator (in another terminal):
#        cd /path/to/confirmate/core
#        go run ./cmd/orchestrator -- --db-in-memory \
#                                     --create-default-target-of-evaluation
#      The orchestrator listens on http://localhost:8080 by default.
#
#   2. Discover the default target_of_evaluation_id:
#        curl -s http://localhost:8080/v1/orchestrator/targets_of_evaluation \
#          | ruby -rjson -e 'puts JSON.parse($stdin.read).dig("targets_of_evaluation", 0, "id")'
#
#   3. Run the smoke test:
#        CONFIRMATE_URL=http://localhost:8080 \
#        TOE_ID=<uuid-from-step-2>           \
#          ruby tests/smoke.rb
#
# If CONFIRMATE_URL is not set or the server is unreachable, the test skips
# rather than fails — making it CI-safe.
# =============================================================================

require 'logger'
require 'json'
require 'net/http'
require 'uri'

$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))
require 'ontology_mapper'
require 'confirmate_client'

CONFIRMATE_URL = ENV['CONFIRMATE_URL'] || 'http://localhost:8080'
TOE_ID         = ENV['TOE_ID']         || '00000000-0000-0000-0000-000000000001'

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
  warn '     Start it with: go run ./cmd/orchestrator -- --db-in-memory --create-default-target-of-evaluation'
  exit 0
end

config = {
  'confirmate' => {
    'endpoint' => CONFIRMATE_URL,
    'auth' => { 'enabled' => false }
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
