#!/usr/bin/env ruby
# Edits GitOps desired state only, after live read-only gates. Never syncs or pushes.
require 'yaml'
require 'json'
require 'open3'
ROOT = File.expand_path('..', __dir__)
STAGES = %w[vault pki certificates istio qualification enrollment].freeze
require_relative 'cluster'
def app(name)
  o = JSON.parse(run_argo('kubectl', '-n', 'argocd', 'get', 'application', application_name(name), '-o', 'json'))
  raise "#{name} must be Synced and Healthy" unless o.dig('status','sync','status') == 'Synced' && o.dig('status','health','status') == 'Healthy'
end
stage = ARGV.fetch(0); index = STAGES.index(stage); abort 'Unknown stage' unless index
path = "#{ROOT}/clusters/#{CLUSTER_ID}/values.yaml"; k = YAML.safe_load(File.read(path))
STAGES.take(index).reject { |s| CLUSTER['role']!='management' && %w[vault pki].include?(s) }.each { |s| raise "Promote #{s} first" unless k['stages'][s] }
if CLUSTER['role']=='management'
  app('longhorn'); app('crossplane'); app('vault-provider')
else
  raise 'Vault and PKI services remain owned by management' if %w[vault pki].include?(stage)
end
case stage
when 'vault'
  %w[vault-tls vault-seal vault-kms].each { |s| run('kubectl','-n','vault','get','secret',s,'-o','name') }
when 'pki'
  app('vault')
  3.times do |i|
    status = JSON.parse(run('kubectl','-n','vault','exec',"vault-#{i}",'--','vault','status','-format=json'))
    raise 'All Vault members must be initialized and unsealed' unless status['initialized'] && !status['sealed'] && status['storage_type']=='raft'
  end
  # Requires operator bootstrap-auth.sh before PKI reconciliation can start.
  run('kubectl','-n','crossplane-system','get','configmap','vault-bootstrap-ca','-o','name')
when 'certificates'
  app('vault-pki')
  raise 'Export and review verified public root trust first' unless File.exist?("#{ROOT}/configuration/mesh-prerequisites/templates/root-ca.yaml")
when 'istio'
  app('cert-manager'); app('vault-issuer'); app('mesh-prerequisites')
  run('kubectl','-n','istio-system','wait','--for=condition=Ready','issuer/vault-istio','--timeout=30s')
when 'qualification'
  app('cert-manager-istio-csr'); app('istiod'); app('istio-base')
  run('kubectl','-n','istio-system','wait','--for=condition=Ready','certificate/istiod','--timeout=30s')
when 'enrollment'
  app('mesh-qualification')
  run('python3',"#{ROOT}/ops/verify-mesh.py",'--permissive','--require-renewal','--cluster',CLUSTER_ID,'--context',CONTEXT)
end
k['stages'][stage] = true; File.write(path,k.to_yaml)
puts "Enabled #{stage} locally. Review the diff and publish separately; nothing applied or pushed."
