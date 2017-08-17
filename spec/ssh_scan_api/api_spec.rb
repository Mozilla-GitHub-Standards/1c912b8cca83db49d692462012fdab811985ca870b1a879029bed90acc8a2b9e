ENV['RACK_ENV'] = 'test'
require 'spec_helper'
require 'ssh_scan_api'
require 'rack/test'
require 'json'

describe SSHScan::API do
  include Rack::Test::Methods

  def app
    SSHScan::API.new
  end

  it "should be able to GET / correctly" do
    get "/"
    expect(last_response.status).to eql(200)
    expect(last_response.body).to eql(
      "See API documentation here: \
https://github.com/mozilla/ssh_scan_api/wiki/ssh_scan-Web-API\n"
    )
  end

  it "should be able to GET __version__ correctly" do
    get "/__version__"
    expect(last_response.status).to eql(200)
    expect(last_response.body).to eql({
      :ssh_scan_version => SSHScan::VERSION,
      :api_version => SSHScan::API_VERSION
    }.to_json)
  end

  it "should be able to POST /scan correctly" do
    bad_ip = "192.168.255.255"
    port = 22
    post "/api/v1/scan", {:target => bad_ip, :port => port}
    expect(last_response.status).to eql(200)
    expect(last_response["Content-Type"]).to eql("application/json")
  end

  it "should be able to GET /scan/results correctly" do
    get "/api/v1/scan/results"
    expect(last_response.status).to eql(200)
    expect(last_response.body).to eql({
      "error" => "no uuid specified"
    }.to_json)
  end

  it "should send a positive response on GET __lbheartbeat__\
  if the API is working" do
    get "/api/v1/__lbheartbeat__"
    expect(last_response.status).to eql(200)
    expect(last_response.body).to eql({
      :status => "OK",
      :message => "Keep sending requests. I am still alive."
    }.to_json)
  end

  # it "should generate a stats report" do
  #   get "/api/v1/stats"
  #   expect(last_response.status).to eql(200)
  #   expect(last_response.body["SCAN_STATES"]).not_to be nil
  #   expect(last_response.body["QUEUED_MAX_AGE"]).not_to be nil
  #   expect(last_response.body["GRADE_REPORT"]).not_to be nil
  # end

  it "should return string uuid" do
    ip = "192.168.1.1"
    port = 22
    post "/api/v1/scan", {:target => ip, :port => port}
    expect(last_response.status).to eql(200)
    expect(last_response.body).to be_kind_of(::String)
    expect(last_response["Content-Type"]).to eql("application/json") 
  end
end
