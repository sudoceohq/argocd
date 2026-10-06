#!/usr/bin/env ruby
# Offline contracts and exact artifact rendering; no cluster calls.
require 'yaml'
require 'json'
require 'digest'
require 'open3'
require 'tempfile'
ROOT = File.expand_path('..', __dir__)
CACHE = ENV.fetch('CHART_CACHE')
HELM = ENV.fetch('HELM', 'helm')
def check(value, message)
  raise message unless value
end
def documents(text)
  text.split(/^---\s*$/).reject { |s| s.strip.empty? }.map { |s| YAML.safe_load(s, permitted_classes: [Time], aliases: true) }.compact
end
def render(*args)
  output, error, status = Open3.capture3(*args)
  raise error unless status.success?
  documents(output)
end
def validate(value, schema, location)
  return if value.nil?
  type = schema['type']
  valid = case type
          when 'object' then value.is_a?(Hash)
          when 'array' then value.is_a?(Array)
          when 'string' then value.is_a?(String)
          when 'integer' then value.is_a?(Integer)
          when 'number' then value.is_a?(Numeric)
          when 'boolean' then [true, false].include?(value)
          else true
          end
  check(valid, "#{location}: expected #{type}")
  check(schema['enum'].include?(value), "#{location}: invalid enum") if schema['enum']
  if value.is_a?(Hash) && schema['properties']
    (schema['required'] || []).each { |key| check(value.key?(key), "#{location}: missing #{key}") }
    value.each do |key, item|
      child = schema['properties'][key]
      check(child || schema['additionalProperties'] || schema['x-kubernetes-preserve-unknown-fields'], "#{location}: unknown field #{key}")
      validate(item, child, "#{location}.#{key}") if child
    end
  elsif value.is_a?(Array) && schema['items']
    value.each { |item| validate(item, schema['items'], location) }
  end
end
lock = JSON.parse(File.read("#{ROOT}/dependencies.lock.json"))
(lock['charts'] + lock['vaultProvider']['schemas']).each do |artifact|
  file = "#{CACHE}/#{artifact['archive'] || artifact['file']}"
  check(Digest::SHA256.file(file).hexdigest == artifact['sha256'], "Locked artifact mismatch #{file}")
end
schemas = lock['vaultProvider']['schemas'].map { |s| YAML.safe_load(File.read("#{CACHE}/#{s['file']}"), aliases: true) }
stage_flags = %w[vault pki certificates istio qualification enrollment].flat_map { |s| ['--set', "stages.#{s}=true"] }
apps = render(HELM, 'template', 'management', "#{ROOT}/clusters/management", *stage_flags)
by_name = apps.to_h { |a| [a['metadata']['name'], a] }
order = %w[longhorn crossplane vault-provider vault vault-pki cert-manager mesh-prerequisites vault-issuer cert-manager-istio-csr istio-base istiod mesh-qualification mesh-enrollment]
waves = order.map { |name| by_name.fetch(name).dig('metadata', 'annotations', 'argocd.argoproj.io/sync-wave').to_i }
check(waves.each_cons(2).all? { |a,b| a < b }, 'Dependency waves must follow deployment order')
rendered = {}
apps.each do |app|
  check(!app.dig('metadata','finalizers'), 'No cascading application deletion')
  check(app.dig('spec','syncPolicy','automated','prune') == false, 'No automated infrastructure pruning')
  source = app.dig('spec','source')
  chart = "#{ROOT}/#{source['path']}"
  values = source.dig('helm','valueFiles').flat_map { |f| ['-f',File.expand_path(f, chart)] }
  rendered[app['metadata']['name']] = render(HELM, 'template', source.dig('helm','releaseName'), chart,
    '--namespace',app.dig('spec','destination','namespace'),'--kube-version','1.36.5','--include-crds',
    *(source.dig('helm','skipTests') ? ['--skip-tests'] : []),*values)
  dependency = YAML.safe_load(File.read("#{chart}/Chart.yaml"))['dependencies']
  if dependency
    artifact = lock['charts'].find { |l| l['chart']==dependency[0]['name'] && l['version']==dependency[0]['version'] }
    check(artifact, 'Every dependency must have an exact artifact pin')
    check(Digest::SHA256.file("#{chart}/charts/#{artifact['archive']}").hexdigest==artifact['sha256'], 'Vendored dependency must match SHA256 lock')
    chart_lock = YAML.safe_load(File.read("#{chart}/Chart.lock"),permitted_classes:[Time])
    check(chart_lock['dependencies'][0]['version']==dependency[0]['version'], 'Helm lock version mismatch')
    canonical = dependency.map { |d| %w[name version repository].to_h { |k| [k,d.fetch(k)] } }
    expected = 'sha256:'+Digest::SHA256.hexdigest(JSON.generate([canonical,chart_lock['dependencies']]))
    check(chart_lock['digest']==expected, 'Helm dependency lock digest mismatch')
  end
end
def configuration(name)
  render(HELM,'template',name,"#{ROOT}/configuration/#{name}")
end
Dir["#{ROOT}/configuration/*"].each do |directory|
  objects = configuration(File.basename(directory))
  objects.select { |o| o['apiVersion'].include?('vault.upbound.io') }.each do |object|
    crd = schemas.find { |s| s.dig('spec','group') == object['apiVersion'].split('/')[0] && s.dig('spec','names','kind') == object['kind'] }
    check(crd, "Missing official provider schema for #{object['kind']}")
    version = crd['spec']['versions'].find { |v| v['name'] == object['apiVersion'].split('/')[1] }
    validate(object['spec'],version['schema']['openAPIV3Schema']['properties']['spec'],object['metadata']['name'])
    if object['kind'] != 'ProviderConfig'
      check(object['spec']['deletionPolicy']=='Orphan' && !object['spec']['managementPolicies'].include?('Delete'), 'Vault resources must resist deletion')
    end
    if object['kind'].match?(/RootCert|IntermediateCertRequest/)
      check(object.dig('spec','forProvider','type')=='internal', 'Never export CA keys')
      check(object.dig('spec','managementPolicies')==%w[Observe Create], 'Never update CA generation automatically')
    end
  end
end
vault = rendered.fetch('vault')
sts = vault.find { |o| o['kind']=='StatefulSet' }
check(sts.dig('spec','replicas')==3 && sts.dig('spec','updateStrategy','type')=='OnDelete', 'Vault must be Raft HA with controlled upgrades')
pod = sts.dig('spec','template','spec'); container = pod['containers'].find { |c| c['name']=='vault' }
check(pod.dig('affinity','podAntiAffinity','requiredDuringSchedulingIgnoredDuringExecution').length==1, 'Vault pod separation must be required')
check(container.dig('readinessProbe','httpGet','path')=='/v1/sys/health?standbyok=true', 'Never mark sealed/uninitialized Vault ready')
check(container['args'].join.include?('-config=/vault/userconfig/vault-seal/seal.hcl'), 'External GCP seal config must be loaded')
check(sts['spec']['volumeClaimTemplates'].all? { |pvc| pvc.dig('spec','storageClassName')=='longhorn' }, 'Protect Raft/audit data with Longhorn')
check(sts.dig('spec','persistentVolumeClaimRetentionPolicy') == {'whenDeleted'=>'Retain','whenScaled'=>'Retain'}, 'Vault claims must retain data')
check(vault.any? { |o| o['kind']=='PodDisruptionBudget' && o.dig('spec','maxUnavailable')==1 }, 'Vault must protect quorum during disruption')
check(vault.none? { |o| o['kind']=='Job' || o.dig('metadata','annotations','argocd.argoproj.io/hook')=='PostSync' }, 'No initialization/unseal readiness hooks')
config = vault.find { |o| o['kind']=='ConfigMap' }.fetch('data').values.join
check(config.include?('tls_cert_file') && !config.include?('tls_disable = 1'), 'Vault listener must use independent TLS')
csr = rendered.fetch('cert-manager-istio-csr')
certificate = csr.find { |o| o['kind']=='Certificate' }
check(certificate.dig('spec','issuerRef','name')=='vault-istio' && certificate.dig('spec','uris')==['spiffe://mgmt.thriftystack.internal/ns/istio-system/sa/istiod-service-account'], 'Istiod identity must use Vault issuer and management trust domain')
check(certificate.dig('spec','privateKey','rotationPolicy')=='Always' && certificate.dig('spec','renewBefore')=='30m', 'Istiod certificates must rotate automatically')
istiod = rendered.fetch('istiod').find { |o| o['kind']=='Deployment' }
env = istiod.dig('spec','template','spec','containers')[0]['env']
check(env.any? { |e| e['name']=='ENABLE_CA_SERVER' && e['value']=='false' }, 'Istiod internal CA must be disabled')
check(istiod.dig('spec','template','spec','volumes').any? { |v| v.dig('secret','secretName')=='istiod-tls' }, 'Istiod must consume istio-csr control-plane certificate')
issuer = configuration('vault-issuer').find { |o| o['kind']=='Issuer' }
check(issuer.dig('spec','vault','path')=='pki-management/sign/istio' && issuer.dig('spec','vault','auth','kubernetes','serviceAccountRef','name')=='istio-vault-auth', 'Signer uses constrained intermediate and short-lived SA auth')
# Validate native cert-manager fields against the pinned chart CRD too.
issuer_crd = rendered['cert-manager'].find { |o| o['kind']=='CustomResourceDefinition' && o.dig('spec','names','kind')=='Issuer' }
validate(issuer['spec'], issuer_crd['spec']['versions'].find { |v| v['name']=='v1' }['schema']['openAPIV3Schema']['properties']['spec'], 'Vault Issuer')
strict = configuration('mesh-enrollment')
check(strict.all? { |o| o['kind']=='PeerAuthentication' && o.dig('metadata','namespace')=='mesh-test' && o.dig('spec','mtls','mode')=='STRICT' }, 'STRICT is scoped to enrolled workloads, never system namespaces')
provider = configuration('vault-provider').find { |o| o['kind']=='Provider' }
check(provider.dig('spec','package') == lock['vaultProvider']['package'], 'Provider package digest must match dependency lock')
check(provider.dig('spec','runtimeConfigRef','name')=='vault-provider', 'Provider must use its named SA/TLS runtime config')
check(configuration('vault-provider').any? { |o| o['kind']=='ValidatingAdmissionPolicyBinding' && o.dig('spec','validationActions')==['Deny'] }, 'Native protected resource deletion guard must remain enabled')
check(File.read("#{ROOT}/ops/promote.rb").include?("'--require-renewal'"), 'STRICT promotion requires natural renewal evidence')
puts "PKI/GitOps offline contracts: passed; rendered #{rendered.length} pinned charts and all custom Helm charts"
# Remote profile is inert by default and creates only namespaced cluster destinations when explicitly staged.
oci = "#{ROOT}/clusters/oci"
check(render(HELM,'template','oci',"#{ROOT}/clusters/management",'-f',"#{oci}/values.yaml",'-f',"#{oci}/cluster.yaml").empty?, 'Unconfigured OCI must render nothing')
remote_flags = ['--set','cluster.enabled=true','--set','cluster.prepared=true','--set','cluster.server=https://oci-api.invalid:6443','--set','cluster.vaultAddress=https://vault.private.invalid:8200']
remote_apps = render(HELM,'template','oci',"#{ROOT}/clusters/management",'-f',"#{oci}/values.yaml",'-f',"#{oci}/cluster.yaml",*stage_flags,*remote_flags)
check(remote_apps.length==8, 'Workload cluster must not deploy management storage, Crossplane, Vault or root PKI')
remote_apps.each do |a|
  check(a.dig('metadata','name').start_with?('oci-') && a.dig('spec','project')=='oci', 'Remote Applications must be cluster-scoped')
  check(a.dig('spec','destination','server')=='https://oci-api.invalid:6443', 'Remote destination isolation')
  path="#{ROOT}/#{a.dig('spec','source','path')}"
  values=a.dig('spec','source','helm','valueFiles').flat_map { |f| ['-f',File.expand_path(f,path)] }
  objects=render(HELM,'template',a.dig('spec','source','helm','releaseName'),path,'--namespace',a.dig('spec','destination','namespace'),*values,*remote_flags)
  if a.dig('metadata','name')=='oci-cert-manager-istio-csr'
    c=objects.find { |o| o['kind']=='Certificate' }
    check(c.dig('spec','uris')==['spiffe://oci.thriftystack.internal/ns/istio-system/sa/istiod-service-account'], 'OCI must never use management SPIFFE identities')
  end
end
remote_pki=render(HELM,'template','oci-pki',"#{ROOT}/configuration/vault-pki",'-f',"#{oci}/cluster.yaml")
check(remote_pki.none? { |o| %w[SecretBackendRootCert ProviderConfig AuthBackendConfig].include?(o['kind']) }, 'Remote PKI must reuse central provider/root and cannot use the local reviewer')
check(remote_pki.find { |o| o['kind']=='SecretBackendRole' }.dig('spec','forProvider','allowedUriSans')==['spiffe://oci.thriftystack.internal/ns/*/sa/*'], 'OCI intermediate URI constraint')
check(remote_pki.find { |o| o['kind']=='SecretBackendRole' }.dig('metadata','name')=='oci-istio', 'Central PKI resources must not collide across clusters')
# Namespace admission, CSR address and storage policy selectors must still match actual dependency names.
check(sts.dig('metadata','name')=='vault' && sts.dig('spec','template','metadata','labels','app.kubernetes.io/name')=='vault','Wrapper must preserve Vault service and pod identities')
check(rendered['cert-manager'].any? { |o| o['kind']=='ServiceAccount' && o.dig('metadata','name')=='cert-manager' }, 'Vault token RBAC must bind the real controller SA')
check(csr.any? { |o| o['kind']=='Service' && o.dig('metadata','name')=='cert-manager-istio-csr' }, 'Istiod CA address must resolve to the rendered signer service')
puts 'Management and inactive/synthetic OCI Helm contracts: passed (no live registration or deployment)'
_, _, invalid = Open3.capture3(HELM,'template','oci',"#{ROOT}/clusters/management",'-f',"#{oci}/values.yaml",'-f',"#{oci}/cluster.yaml",'--set','cluster.enabled=true')
check(!invalid.success?, 'Unprepared OCI activation must fail')
_, _, invalid = Open3.capture3(HELM,'template','wrong-domain',"#{ROOT}/charts/cert-manager-istio-csr",'-f',"#{oci}/cluster.yaml")
check(!invalid.success?, 'Management signer defaults must fail for an OCI cluster without domain overrides')
