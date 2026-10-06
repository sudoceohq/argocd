#!/usr/bin/env ruby
# Public CSR and CA certificate handoff only. All private CA keys remain in Vault.
require 'json'
require 'yaml'
require 'open3'
require 'tempfile'
ROOT = File.expand_path('..', __dir__)
require_relative 'cluster'
raise 'CA handoff runs against the management Crossplane context' unless CLUSTER['role']=='management'
def ready(kind, name)
  o = JSON.parse(run('kubectl', 'get', kind, name, '-o', 'json'))
  %w[Ready Synced].each do |type|
    raise "#{name} is not #{type}" unless o.fetch('status').fetch('conditions').any? { |c| c['type'] == type && c['status'] == 'True' }
  end
  o.fetch('status').fetch('atProvider')
end
def add_file(directory, filename, objects)
  path = "#{ROOT}/#{directory}/templates/#{filename}"
  text = objects.map(&:to_yaml).join
  text = "{{ if eq .Values.cluster.id \"#{TARGET_ID}\" }}\n#{text}{{ end }}\n" unless filename=='root-ca.yaml'
  raise 'Existing public artifact differs; use the rotation runbook, never overwrite a CA generation' if File.exist?(path) && File.read(path) != text
  File.write(path, text)

end
def managed(kind, name, fields, wave)
  {'apiVersion'=>'pki.vault.upbound.io/v1alpha1','kind'=>kind,
   'metadata'=>{'name'=>name,'annotations'=>{'argocd.argoproj.io/sync-wave'=>wave.to_s,'argocd.argoproj.io/sync-options'=>'Prune=false,Delete=false'}},
   'spec'=>{'deletionPolicy'=>'Orphan','managementPolicies'=>%w[Observe Create], 'providerConfigRef'=>{'name'=>'management-vault'},'forProvider'=>fields}}
end
TARGET_ID = ARGV.fetch(1, 'management')
raise 'Invalid PKI cluster ID' unless TARGET_ID.match?(/\A[a-z][a-z0-9-]*\z/)
TARGET = YAML.safe_load(File.read("#{ROOT}/clusters/#{TARGET_ID}/cluster.yaml")).fetch('cluster')
case ARGV.fetch(0)
when 'sign'
  ready('secretbackendrootcerts.pki.vault.upbound.io', 'workload-root')
  csr = ready('secretbackendintermediatecertrequests.pki.vault.upbound.io', TARGET.fetch('issuerGeneration')).fetch('csr')
  Tempfile.create('management-public-csr') do |f|
    f.write(csr); f.flush
    run('openssl', 'req', '-in', f.path, '-verify', '-noout')
  end
  sign = managed('SecretBackendRootSignIntermediate', TARGET.fetch('issuerGeneration'), {
    'backend'=>'pki-root','issuerRef'=>'root-2026','csr'=>csr,'commonName'=>TARGET.fetch('issuerCommonName'),
    'format'=>'pem_bundle','ttl'=>'31536000','maxPathLength'=>0,'permittedUriDomains'=>[TARGET.fetch('trustDomain')]}, -15)
  install = managed('SecretBackendIntermediateSetSigned', TARGET.fetch('issuerGeneration'), {
    'backend'=>TARGET.fetch('pkiMount'),'certificateRef'=>{'name'=>TARGET.fetch('issuerGeneration')}}, -14)
  add_file('configuration/vault-pki', "#{TARGET_ID}-signed.yaml", [sign, install])
  puts 'Prepared public CSR signing/import resources. Review and publish through GitOps; no API writes performed.'
when 'trust'
  root = ready('secretbackendrootcerts.pki.vault.upbound.io', 'workload-root').fetch('certificate')
  intermediate = ready('secretbackendintermediatesetsigneds.pki.vault.upbound.io', TARGET.fetch('issuerGeneration')).fetch('certificate')
  Tempfile.create('root-public-ca') do |r|
    Tempfile.create('intermediate-public-ca') do |i|
      r.write(root); r.flush; i.write(intermediate); i.flush
      run('openssl', 'verify', '-CAfile', r.path, i.path)
      run('openssl', 'x509', '-in', i.path, '-checkend', '2592000', '-noout')
      text = run('openssl', 'x509', '-in', i.path, '-text', '-noout')
      raise 'Intermediate must be constrained to one management trust domain and no subordinate CAs' unless text.include?('CA:TRUE, pathlen:0') && text.include?("URI:#{TARGET.fetch('trustDomain')}")
      fingerprint = run('openssl', 'x509', '-in', r.path, '-fingerprint', '-sha256', '-noout').strip
      puts fingerprint
    end
  end
  trust = {'apiVersion'=>'v1','kind'=>'ConfigMap','metadata'=>{'name'=>'istio-root-ca','namespace'=>'cert-manager','annotations'=>{'argocd.argoproj.io/sync-options'=>'Prune=false,Delete=false'}},'data'=>{'ca.pem'=>root}}
  add_file('configuration/mesh-prerequisites', 'root-ca.yaml', [trust])
  puts 'Prepared pinned public root trust. Independently verify the fingerprint and publish before installing istio-csr.'
else
  abort 'Usage: ruby ops/pki-handoff.rb sign|trust'
end
