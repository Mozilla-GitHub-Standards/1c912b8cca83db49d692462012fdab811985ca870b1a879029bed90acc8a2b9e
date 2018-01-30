require 'sinatra'
require 'sinatra/activerecord'
require 'sinatra/namespace'
require 'securerandom'
require 'secure_headers'
require 'ssh_scan_api/models/scan'
require 'ssh_scan_api/target_validator'
require 'ssh_scan_api/authenticator'
require 'pg'

class SSHScan::Api < Sinatra::Base
  include SSHScan
  register Sinatra::Namespace

  before do
    content_type :json
  end

  # Configure all the secure headers we want to use
  use SecureHeaders::Middleware
  SecureHeaders::Configuration.default do |config|
    config.cookies = {
      secure: true, # mark all cookies as "Secure"
      httponly: true, # mark all cookies as "HttpOnly"
    }
    config.hsts = "max-age=31536000; includeSubdomains; preload"
    config.x_frame_options = "DENY"
    config.x_content_type_options = "nosniff"
    config.x_xss_protection = "1; mode=block"
    config.x_download_options = "noopen"
    config.x_permitted_cross_domain_policies = "none"
    config.referrer_policy = "no-referrer"
    config.csp = {
      default_src: ["'none'"],
      script_src: ["'none'"],
      frame_ancestors: ["'none'"],
      upgrade_insecure_requests: true, # see https://www.w3.org/TR/upgrade-insecure-requests/
    }
  end

  before do
    headers "Access-Control-Allow-Methods" => "GET, POST"
    headers "Access-Control-Allow-Origin" => "*"
    headers "Access-Control-Max-Age" => "86400"
    headers "Cache-control" => "no-store"
    headers "Pragma" => "no-cache"
    headers "Server" => "ssh_scan_api"
  end

  # Custom 404 handling
  not_found do
    content_type "text/plain"
    "Invalid request, see API documentation here: \
https://github.com/mozilla/ssh_scan_api/wiki/ssh_scan-Web-API\n"
  end

  get '/' do
    content_type "text/plain"
    "See API documentation here: \
https://github.com/mozilla/ssh_scan_api/wiki/ssh_scan-Web-API\n"
  end

  get '/robots.txt' do
    content_type "text/plain"
    "User-agent: *\nDisallow: /\n"
  end

  get '/contribute.json' do
    content_type :json
    SSHScan::Constants::CONTRIBUTE_JSON.to_json
  end

  get '/__version__' do
    {
      :api_version => SSHScan::API_VERSION,
    }.to_json
  end

  namespace "/api/v1" do

    post '/scan' do
      port = params["port"] || 22

      # Check to see if there is a recent scan we offer
      begin
        latest_scan = Scan.where(["target = ? and port = ?", "sshscan.rubidus.com", 22]).last

        # Return prior scan results if run within 2min of now
        if latest_scan && (Time.now - latest_scan.creation_time < 120)
          return {"uuid": latest_scan.scan_id}.to_json
        end
      rescue
        ActiveRecord::Base.connection_pool.release_connection
      end

      # Perform a new scan
      begin
        scan = Scan.new do |s|
          s.scan_id = SecureRandom.uuid
          s.creation_time = Time.now
          s.target = params["target"]
          s.port = port
          s.state = "QUEUED"
          s.save
        end
      ensure
        ActiveRecord::Base.connection_pool.release_connection
      end

      return {"uuid": scan.scan_id}.to_json
    end

    get '/scan/results' do
      uuid = params[:uuid]

      # If we don't get a uuid, we don't know what scan to pick up
      return {"error" => "no uuid specified"}.to_json if uuid.nil? || uuid.empty?

      begin
        scan = Scan.find_by("scan_id": uuid)
      ensure
        ActiveRecord::Base.connection_pool.release_connection
      end

      if scan.nil?
        return {"scan" => "UNKNOWN"}.to_json
      end

      case scan.state
      when "QUEUED"
        return {"status" => "QUEUED"}.to_json
      when "ERRORED"
        return {"status" => "ERRORED"}.to_json
      when "RUNNNING"
        return {"status" => "RUNNNING"}.to_json
      when "COMPLETED"
        return scan.raw_scan
      else
        return {"scan" => "UNKNOWN"}.to_json
      end
    end

    get '/stats' do
      queued_max_age = 0

      begin
        oldest = Scan.where(state: "QUEUED").minimum(:creation_time)
      ensure
        ActiveRecord::Base.connection_pool.release_connection
      end

      if oldest
        queued_max_age = (Time.now - oldest).to_i
      end

      begin
        report = {
          "SCAN_STATES" => {
            "QUEUED" => Scan.where(state: "QUEUED").count,
            "BATCH_QUEUED" => Scan.where(state: "BATCH_QUEUED").count,
            "RUNNING" => Scan.where(state: "RUNNING").count,
            "ERRORED" => Scan.where(state: "ERRORED").count,
            "COMPLETED" => Scan.where(state: "COMPLETED").count,
          },
         "QUEUED_MAX_AGE" => queued_max_age,
          "GRADE_REPORT" => {
            "A" => Scan.where(grade: "A").count,
            "B" => Scan.where(grade: "B").count,
            "C" => Scan.where(grade: "C").count,
            "D" => Scan.where(grade: "D").count,
            "F" => Scan.where(grade: "F").count,
          }
          # "AUTH_METHOD_REPORT" => settings.db.auth_method_report
        }
      ensure
        ActiveRecord::Base.connection_pool.release_connection
      end

      return report.to_json
    end

    # get '/scans' do
    #   @scans = Scan.all
    #   @scans.to_json
    # end

    get '/__lbheartbeat__' do
      {
        :status  => "OK",
        :message => "Keep sending requests. I am still alive."
      }.to_json
    end
  end

  def self.run!(options = {}, &block)
    set options

    configure do
      enable :logging
      set :bind, ENV['SSHAPIBIND'] || options["bind"] || '127.0.0.1'
      set :port, 8000
      db_configs = YAML.load_file(File.join(File.dirname(__FILE__),"../../config/database.yml"))
      set :database, db_configs[ENV['SSHSCANDATABASEENV']] || db_configs[options["database_environment"]]
      set :server, 'thin'
      set :logger, Logger.new(STDOUT)
      set :target_validator, SSHScan::TargetValidator.new(File.join(File.dirname(__FILE__),"../../config/api/config.yml"))    
      set :authenticator, SSHScan::Authenticator.new(File.join(File.dirname(__FILE__),"../../config/api/config.yml")) 
      set :environment, :test
      set :allowed_ports, [22]
      set :protection, false
    end

    super do |server|
      # No SSL on app, SSL termination happens in nginx for a prod deployment
      server.ssl = false
    end
  end

end