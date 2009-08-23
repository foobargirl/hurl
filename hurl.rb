require 'libraries'

module Hurl
  def self.redis
    @redis
  end

  def self.redis=(redis)
    @redis = redis
  end

  class App < Sinatra::Base
    dir = File.dirname(File.expand_path(__FILE__))

    set :views,  "#{dir}/views"
    set :public, "#{dir}/public"
    set :static, true

    enable :sessions

    def initialize(*args)
      super
      Hurl.redis = Redis.new(:host => '127.0.0.1', :port => 6379)
    end

    def redis
      Hurl.redis
    end


    #
    # routes
    #

    before do
      if load_session
        @user = User.find_by_email(@session['email'])
      end
    end

    helpers do
      def logged_in?
        !!@user
      end
    end

    get '/' do
      @hurl = {}
      erb :index
    end

    get '/hurls/:id' do
      saved = redis.get(params[:id])
      @hurl = Yajl::Parser.parse(saved)
      erb :index
    end

    get '/hurls/' do
      redirect('/') and return unless @user
      @hurls = @user.hurls
      erb :hurls
    end

    get '/about/' do
      erb :about
    end

    get '/signout/' do
      clear_session
      redirect '/'
    end

    post '/signin/' do
      email, password = params.values_at(:email, :password)

      if User.authenticate(email, password)
        create_session(:email => email)
        json :success => true
      else
        json :error => 'incorrect email or password'
      end
    end

    post '/signup/' do
      email, password = params.values_at(:email, :password)
      user = User.create(:email => email, :password => password)

      if user.valid?
        create_session(:email => email)
        json :success => true
      else
        json :error => user.errors.to_s
      end
    end

    post '/' do
      url, method, auth = params.values_at(:url, :method, :auth)
      curl = Curl::Easy.new(url)

      requests = []
      curl.on_debug do |type, data|
        # track request headers
        requests << data if type == Curl::CURLINFO_HEADER_OUT
      end

      curl.follow_location = true if params[:follow_redirects]

      # ensure a method is set
      method = (method.to_s.empty? ? 'GET' : method).upcase

      # update auth
      add_auth(auth, curl, params)

      # arbitrary headers
      clean_arrays(params["header-keys"], params["header-vals"])
      add_headers_from_arrays(curl, params["header-keys"], params["header-vals"])

      # arbitrary params
      clean_arrays(params["param-keys"], params["param-vals"])
      fields = make_fields(method, params["param-keys"], params["param-vals"])

      begin
        curl.send("http_#{method.downcase}", *fields)
        json :header  => pretty_print_headers(curl.header_str),
             :body    => pretty_print(curl.content_type, curl.body_str),
             :request => pretty_print_requests(requests, fields),
             :hurl_id => save_hurl(params)
      rescue => e
        json :error => "error: #{e}"
      end
    end

    #
    # error handlers
    #
    not_found do
      erb :"404"
    end

    error do
      erb :"500"
    end

    #
    # http helpers
    #

    # if key or value is empty, remove the pair
    def clean_arrays(keys, values)
      return unless keys.is_a?(Array) && values.is_a?(Array)

      keys.each_with_index do |key, i|
        if keys[i].to_s.empty? or values[i].to_s.empty?
          keys.delete_at(i)
          values.delete_at(i)
        end
      end
    end

    # update auth based on auth type
    def add_auth(auth, curl, params)
      if auth == 'basic'
        username, password = params.values_at(:username, :password)
        encoded = Base64.encode64("#{username}:#{password}").strip
        curl.headers['Authorization'] = "Basic #{encoded}"
      end
    end

    # headers from non-empty keys and values
    def add_headers_from_arrays(curl, keys, values)
      keys, values = Array(keys), Array(values)

      keys.each_with_index do |key, i|
        next if values[i].to_s.empty?
        curl.headers[key] = values[i]
      end
    end

    # post params from non-empty keys and values
    def make_fields(method, keys, values)
      return [] unless method == 'POST'

      fields = []
      keys, values = Array(keys), Array(values)
      keys.each_with_index do |name, i|
        value = values[i]
        next if name.to_s.empty? || value.to_s.empty?
        fields << Curl::PostField.content(name, value)
      end
      fields
    end

    def save_hurl(params)
      id = Digest::SHA1.hexdigest(params.to_s)
      json = Yajl::Encoder.encode(params.merge(:id => id))
      redis.set(id, json)
      @user.add_hurl(id) if @user
      id
    end


    #
    # pretty printing
    #

    def pretty_print(type, content)
      type = type.to_s

      if type.include? 'json'
        pretty_print_json(content)
      elsif type.include? 'xml'
        colorize :xml => content
      elsif type.include? 'html'
        colorize :html => content
      else
        content.inspect
      end
    end

    def pretty_print_json(content)
      colorize :js => shell("python -msimplejson.tool", :stdin => content)
    end

    def pretty_print_headers(content)
      lines = content.split("\n").map do |line|
        if line =~ /^(.+?):(.+)$/
          "<span class='nt'>#{$1}</span>:<span class='s'>#{$2}</span>"
        else
          "<span class='nf'>#{line}</span>"
        end
      end

      "<div class='highlight'><pre>#{lines.join}</pre></div>"
    end

    # accepts an array of request headers and formats them
    def pretty_print_requests(requests = [], fields = [])
      headers = requests.map do |request|
        pretty_print_headers request
      end

      headers.join + fields.join('&')
    end


    #
    # sinatra helper methods
    #

    # render a json response
    def json(hash = {})
      headers['Content-Type'] = 'application/json'
      Yajl::Encoder.encode(hash)
    end

    # colorize :js => '{ "blah": true }'
    def colorize(hash = {})
      Albino.colorize(hash.values.first, hash.keys.first)
    end

    # shell "cat", :stdin => "file.rb"
    def shell(cmd, options = {})
      ret = ''
      Open3.popen3(cmd) do |stdin, stdout, stderr|
        if options[:stdin]
          stdin.puts options[:stdin].to_s
          stdin.close
        end
        ret = stdout.read.strip
      end
      ret
    end

    # simple cookie wrapper
    def set_cookie(key, value)
      response.set_cookie(key, :value => value, :expires => Time.now + 31536000)
    end


    #
    # poor man's session handling
    #

    def load_session
      if session_id = session['sid']
        @session = find_session(session_id)
      end
    end

    def find_session(id)
      Yajl::Parser.parse(redis.get(id)) rescue nil
    end

    def create_session(object)
      json = Yajl::Encoder.encode(object)
      id = generate_session_id
      redis.set(id, json)
      session['sid'] = id
    end

    def clear_session
      if session_id = session['sid']
        redis.del(session_id)
        session.delete('sid')
      end
    end

    def generate_session_id
      Digest::SHA1.hexdigest(Time.now.to_s + rand(10_000).to_s)
    end
  end
end
