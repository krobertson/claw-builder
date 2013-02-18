require 'digest/md5'
require 'digest/sha1'
require 'digest/sha2'

require 'rest_client'
require 'thor'
require 'json'
require 'base64'

require 'claw/builder'
require 'claw/builder/websocket'
require 'claw/builder/package_formula'

class Claw::Builder::CLI < Thor

  desc "build FORMULA", <<-DESC
Build a package using the FORMULA file given.

  DESC

  method_option :server, :aliases => "-s", :desc => "the host:port of the build server"

  def build(formula)
    error("Formula file doesn't exist") unless File.exists?(formula)

    server = options[:server] || '127.0.0.1:8080'

    # load the formula
    Dir.chdir File.dirname(File.expand_path(formula))
    $:.unshift File.expand_path('.')
    load File.basename(formula)
    klass = File.read(File.basename(formula))[/class (\w+)/, 1]
    spec = eval(klass).to_spec

    # create build manifest
    manifest = spec.dup
    manifest[:included_files] = []
    spec[:included_files].each do |file|
      i = file.dup
      i.delete :path
      File.open(file[:path], 'rb') do |f|
        i[:data] = Base64.strict_encode64 f.read
      end
      manifest[:included_files] << i
    end

    # initiate the build
    puts ">> Uploading build manifest"
    res = RestClient.post "http://#{server}/build", manifest.to_json, :content_type => :json, :accept => :json
    res = JSON.parse(res)

    puts ">> Tailing build..."

    client = WebSocket.new(res['tail_url'])
    loop do
      begin
        data = client.receive()
        print(data)
      rescue EOFError, IOError
        break
      end
    end

    # get the details
    puts
    puts ">> Getting build result"
    details = RestClient.get res['details_url'], {:accept => :json}
    details = JSON.parse(details)

    # download
    puts ">> Downloading"
    f = open(details['name'], 'wb')
    f.write(RestClient.get(details['url']))
    f.close

    # validating
    puts ">> Validating"
    error "Invalid MD5!"    if Digest::MD5.file(details['name']).hexdigest != details['md5']
    error "Invalid SHA1!"   if Digest::SHA1.file(details['name']).hexdigest != details['sha1']
    error "Invalid SHA256!" if Digest::SHA2.file(details['name']).hexdigest != details['sha256']
    puts ">> Downloaded file at #{details['name']}"

  rescue Interrupt
    error "Aborted by user"
  rescue Errno::EPIPE
    error "Could not connect to build server: #{server}"
  rescue Errno::ECONNREFUSED
    error "Could not connect to build server: #{server}"
  end

private

  def error(message)
    puts "!! #{message}"
    exit 1
  end

end
