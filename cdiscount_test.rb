require 'pry'
require 'curb'
require 'colorize'
require 'ferrum'
require 'digest/md5'
require 'optparse'

class Tester
  USER_AGENTS = [
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/84.0.4147.89 Safari/537.36',
    'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/84.0.4147.89 Safari/537.36',
    'Mozilla/5.0 (Windows NT 10.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/84.0.4147.89 Safari/537.36',
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/84.0.4147.89 Safari/537.36',
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/83.0.4103.106 Safari/537.36',
  ].freeze

  def initialize
    @seed = 'https://www.cdiscount.com'
    @banned = File.readlines('banned', chomp: true).map { |l| l.split("\t").first }
    @proxies = File.readlines('proxies', chomp: true) - @banned
    @validation = ['Too Many Requests']
    setup_curl
    OptionParser.new do |opts|
      opts.on('-c', '--clean', 'Clean old output') do
        ['done', 'error'].each do |directory_name|
          Dir.mkdir(directory_name) unless File.exists?(directory_name)
          FileUtils.rm_f Dir.glob("#{directory_name}/*")
        end
      end
      opts.on('-g', '--generate', 'Generate todos') do
        ['todo', 'done', 'error'].each do |directory_name|
          Dir.mkdir('todo') unless File.exists?('todo')
          FileUtils.rm_f Dir.glob('todo/*')
          File.readlines('urls', chomp: true).each do |url|
            save_todo(url, 0)
            save_todo(url, 0)
            save_todo(url, 0)
            save_todo(url, 0)
            save_todo(url, 0)
          end
        end
      end
    end.parse!
  end

  def setup_curl
    @curl = Curl::Easy.new
    @curl.follow_location = true
    @curl.enable_cookies = true
    @curl.header_in_body = true
    @curl.encoding = '' # позволяет автоматом разжимать gzip/deflate
    @curl.on_complete do |curl_response|
      encoding = 'UTF-8'
      encoding = $1 if curl_response.header_str =~ /charset=([-a-z0-9]+)/i
      encoding = $1 if curl_response.body_str =~ %r{<meta[^>]+content=[^>]*charset=([-a-z0-9]+)[^>]*>}mi
      curl_response.body_str.force_encoding(encoding)
    end
    # @curl.headers = File.readlines('curl', chomp: true).map { |line| line[%r{-H\s*['"](?!cookie:)(.*)['"]}, 1] }.compact.map { |line| line.split(': ', 2) }.to_h
    @curl.headers = {
      'accept-encoding' => 'gzip,deflate,identity',
      'accept-language' => 'en-us,en;q=0.5',
      'accept' => '*/*',
    } if @curl.headers.empty?
    @curl.on_debug { |type, data| @last_request = data if type == 2 }
  end

  def hash(url)
    "#{url[%r{/f-\d+-(\w+)\.htm}, 1] || Digest::MD5.hexdigest(url)}"
  end

  def save_todo(url, attempt)
    File.write(loop do
      filename = "todo/#{hash(url)}_#{attempt}_#{Digest::MD5.hexdigest(rand().to_s)}"
      break filename unless File.exist?(filename)
    end, "#{url}\t#{attempt}")
  end

  def ban(proxy)
    puts "Banned #{proxy}".red
    File.open('banned', 'a') do |f|
      f.puts "#{proxy}\t#{@downloads_per_proxy}"
    end
    @banned.push(proxy)
    @proxies.delete(proxy)
  end

  def login(proxy)
    puts "Login started, proxy #{proxy}".yellow
    @user_agent = USER_AGENTS.sample
    @curl.headers['user-agent'] = @user_agent
    browser = Ferrum::Browser.new(browser_path: 'chromium-browser', port: 9222, browser_options: { 'proxy-server' => proxy, 'user-agent' => @user_agent }, process_timeout: 30, timeout: 230, headless: true)
    puts "Page debug url: http://localhost:9222/devtools/inspector.html?ws=localhost:9222/devtools/page/#{browser.goto('about:blank')}".green
    begin
      browser.goto(@seed)
      (1..60).each { |i| sleep 1; break if browser.at_xpath("//div[@class='recommends-home-box__title']") }
      cookies = browser.cookies.all.values.map { |v| "#{v.name}=#{v.value}" }
    ensure
      browser.quit
    end
    puts 'Login finished'.green
    puts cookies
    cookies
  end

  def crawl(url, proxy)
    @curl.url = url
    @curl.proxy_url = proxy
    #puts "Crawl #{url}"
    @curl.perform
    ["#{@last_request}\n#{@curl.body_str}", @curl.response_code]
  end

  def load_proxy
    proxy = @proxies.sample
    raise 'No more proxy' unless proxy
    proxy
  end

  def perform
    files = Dir.glob('todo/**/*').select { |f| File.file? f }.sort_by { |f| File.ctime(f) }
    return if files.empty?
    @downloads_per_proxy = 0
    proxy = load_proxy
    @curl.cookies = login(proxy).join('; ')
    loop do
      files = Dir.glob('todo/**/*').select { |f| File.file? f }.sort_by { |f| File.ctime(f) } if files.empty?
      break if files.empty?
      file = files.shift
      values = File.readlines(file, chomp: true).first.split("\t")
      task = [:url, :attempt].zip([values[0], values[1].to_i]).to_h
      begin
        body, code = crawl(task[:url], proxy)
        task[:attempt] += 1
      ensure
        if [403, 400, 429].include?(code) || @validation.find { |w| body.include?(w) }
          puts "Bad response, url #{task[:url]}, attempt #{task[:attempt]}, code #{code}".red
          filename = "error/#{hash(task[:url])}_#{task[:attempt]}_#{Time.now.strftime('%Y-%m-%d %T')}"
          File.write(filename, task_to_f(task, proxy, body))
          puts "Write #{task[:url]} to #{filename}"
          ban(proxy)
          @downloads_per_proxy = 0
          proxy = load_proxy
          @curl.cookies = login(proxy).join('; ')
          save_todo(task[:url], task[:attempt] + 1) if task[:attempt] <= 5
        else
          @downloads_per_proxy += 1
          proxy = load_proxy
          puts "#{@downloads_per_proxy} successful downloads per proxy #{proxy}, code #{code}".green
          filename = "done/#{hash(task[:url])}_#{task[:attempt]}_#{Time.now.strftime('%Y-%m-%d %T')}"
          File.write(filename, task_to_f(task, proxy, body))
          puts "Write #{task[:url]} to #{filename}"
        end
        File.delete(file)
      end
    end
  end

  def task_to_f(task, proxy, body)
    "#{task[:url]}\t#{task[:attempt]}\nPFProxy: #{proxy}\n#{body}"
  end
end

Tester.new.perform
