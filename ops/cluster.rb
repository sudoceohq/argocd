# Shared operator target selection. No writes; fail before using the wrong API.
require 'yaml'
require 'open3'
ROOT = File.expand_path('..', __dir__) unless defined?(ROOT)
CLUSTER_ID = ENV.fetch('THRIFTY_CLUSTER', 'management')
raise 'Invalid cluster ID' unless CLUSTER_ID.match?(/\A[a-z][a-z0-9-]*\z/)
CLUSTER = YAML.safe_load(File.read("#{ROOT}/clusters/#{CLUSTER_ID}/cluster.yaml")).fetch('cluster')
raise 'Cluster is disabled or external prerequisites are incomplete' unless CLUSTER['enabled'] && CLUSTER['prepared']
CONTEXT = CLUSTER['context'].to_s.empty? ? ENV['KUBE_CONTEXT'] : CLUSTER['context']
raise 'Set KUBE_CONTEXT explicitly (or cluster.context); implicit current contexts are unsafe' if CONTEXT.to_s.empty?
def run(*args)
  args = [args[0], '--context', CONTEXT, *args.drop(1)] if %w[kubectl istioctl].include?(args[0])
  out, err, status = Open3.capture3(*args)
  raise "#{args.first} failed (exit #{status.exitstatus}); captured payload withheld" unless status.success?
  out
end
server = run('kubectl','config','view','--minify','-o','jsonpath={.clusters[0].cluster.server}').strip
raise 'Selected context API does not match the configured cluster.server' unless server==CLUSTER.fetch('operatorServer', CLUSTER.fetch('server'))
def application_name(name)
  CLUSTER_ID=='management' ? name : "#{CLUSTER_ID}-#{name}"
end
# Argo CD Applications always live on management, even for remote destinations.
def run_argo(*args)
  return run(*args) if CLUSTER['role']=='management'
  context = ENV.fetch('ARGO_CONTEXT') { raise 'Set ARGO_CONTEXT to the management operator context' }
  config = YAML.safe_load(File.read("#{ROOT}/clusters/management/cluster.yaml"))['cluster']
  out, _, status = Open3.capture3('kubectl','--context',context,'config','view','--minify','-o','jsonpath={.clusters[0].cluster.server}')
  raise 'ARGO_CONTEXT does not point to management' unless status.success? && out.strip==config.fetch('operatorServer')
  out, _, status = Open3.capture3(args[0],'--context',context,*args.drop(1))
  raise 'Management Argo read failed; payload withheld' unless status.success?
  out
end
