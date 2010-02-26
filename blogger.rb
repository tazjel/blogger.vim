#!/usr/bin/env ruby
require 'net/https'
require 'uri'
require 'rubygems'
require 'nokogiri'
require 'markdown'
require 'net-https-wrapper'
require 'open-uri'

class Array
  # maph :: [a] -> (a -> b) -> Hash
  def maph(&block)
    map(&block).inject({}) {|memo, (key, value)| memo.update(key => value) }
  end
end

class Gist
  def self.create(text,description=nil)
    a = self.new
    a.instance_variable_set("@text",text)
    r = Net::HTTP.post_form(URI.parse('http://gist.github.com/gists'),{'file_contents[gistfile1]' => text,'file_name[gistfile1]' => nil, 'file_ext[gistfile1]' => '.txt'}.merge(self.auth))
    a.instance_variable_set("@url",r['Location'])
    a.instance_variable_set("@gist_id",URI.parse(a.url).path.gsub(/^\//,''))
    a.set_description description unless description.nil?
    a
  end

  def self.load(id)
    self.new(id)
  end

  def set_description(desc)
    p Net::HTTP.post_form(URI.parse('http://gist.github.com/gists/'+@gist_id+'/update_description'),{'description' => desc}.merge(self.class.auth))
    self
  end

  def url
    @url
  end

  def initialize(gist_id=nil)
    raise ArgumentError, 'gist_id is not vaild id' if gist_id.to_i.zero? && !gist_id.nil?
    if gist_id
      @url  = "http://gist.github.com/#{gist_id.to_s}"
      @text = open("#{@url}.txt").read
      @gist_id = gist_id.to_s
    end
  end

  def embed
    '<script src="http://gist.github.com/'+@gist_id+'.js?file=gistfile1.txt"></script>'
  end

  def text
    @text
  end

  def text=(x)
    @text = x
  end

  def gist_id
    @gist_id
  end

  def update
   Net::HTTP.post_form(URI.parse('http://gist.github.com/gists/'+@gist_id),{'file_contents[gistfile1.txt]' => @text,'file_ext[gistfile1.txt]' => '.txt','file_name[gistfile1.txt]' => '', '_method' => 'put'}.merge(self.class.auth))
   self
  end

  def self.auth
    user  = `git config --global github.user`.strip
    token = `git config --global github.token`.strip
 
    user.empty? ? {} : { :login => user, :token => token }
  end
end

module Blogger
  class RateLimitException < Exception; end
  class EmptyEntry < Exception; end

  @@gist = false
  def self.gist; @@gist; end
  def self.gist=(x); @@gist = x; end

  # list :: String -> Int -> IO [Hash]
  def self.list(blogid, page)
    __pagenate_get__(blogid, page).xpath('//xmlns:entry[xmlns:link/@rel="alternate"]').
      map {|i|
        [:published, :updated, :title, :content].
          maph {|s| [s, i.at(s.to_s).content] }.
          update(:uri => i.at('link[@rel="alternate"]')['href'])
      }
  end

  # show :: String -> String -> IO [String]
  def self.show(blogid, uri)
    xml = __find_xml_recursively__(blogid) {|x|
      x.at("//xmlns:entry[xmlns:link/@href='#{uri}']/xmlns:link[@rel='edit']")
    }
    title = xml.at("//xmlns:entry[xmlns:link/@href='#{uri}']/xmlns:title").content
    body = xml.at("//xmlns:entry[xmlns:link/@href='#{uri}']/xmlns:content").content
    body = body.gsub(%r|<div class="blogger-post-footer">.*?</div>|, '')
    __title2firstline__(title) + "\n\n" + html2text(body)
  end

  # login :: String -> String -> String
  def self.login(email, pass)
    a = Net::HTTP.post(
      'https://www.google.com/accounts/ClientLogin',
      {
        'Email' => email,
        'Passwd' => pass,
        'service' => 'blogger',
        'accountType' => 'HOSTED_OR_GOOGLE',
        'source' => 'ujihisa-bloggervim-1'
      }.map {|i, j| "#{i}=#{j}" }.join('&'),
      {'Content-Type' => 'application/x-www-form-urlencoded'})
    a.body.lines.to_a.maph {|i| i.split('=') }['Auth'].chomp
  end

  # create :: String -> String -> String -> IO String
  def self.create(blogid, token, str)
    xml = Net::HTTP.post(
      "http://www.blogger.com/feeds/#{blogid}/posts/default",
      text2xml(str),
      {
        "Authorization" => "GoogleLogin auth=#{token}",
        'Content-Type' => 'application/atom+xml'
      })
    raise RateLimitException if xml.body == "Blog has exceeded rate limit or otherwise requires word verification for new posts"
    Nokogiri::XML(xml.body).at('//xmlns:link[@rel="alternate"]')['href']
  end

  # update :: String -> String -> String -> String -> IO ()
  def self.update(blogid, uri, token, str)
    lines = str.lines.to_a
    title = __firstline2title__(lines.shift.strip)
    body = Markdown.new(lines.join).to_html

    xml = __find_xml_recursively__(blogid) {|x|
      x.at("//xmlns:entry[xmlns:link/@href='#{uri}']/xmlns:link[@rel='edit']")
    }
    put_uri = xml.at("//xmlns:entry[xmlns:link/@href='#{uri}']/xmlns:link[@rel='edit']")['href']

    xml.at("//xmlns:entry[xmlns:link/@href='#{uri}']/xmlns:title").content = title
    xml.at("//xmlns:entry[xmlns:link/@href='#{uri}']/xmlns:content").content = body
    xml.at("//xmlns:entry[xmlns:link/@href='#{uri}']")['xmlns'] = 'http://www.w3.org/2005/Atom'
    Net::HTTP.put(
      put_uri,
      xml.at("//xmlns:entry[xmlns:link/@href='#{uri}']").to_s,
      {
        "Authorization" => "GoogleLogin auth=#{token}",
        'Content-Type' => 'application/atom+xml'
      })
  end

  def self.__find_xml_recursively__(blogid)
    xml = nil
    (0..1/0.0).each do |n|
      xml = __pagenate_get__(blogid, n)
      break if yield(xml)
    end
    xml
  end

  def self.__pagenate_get__(blogid, page)
    xml = Net::HTTP.get(URI.parse(
      "http://www.blogger.com/feeds/#{blogid}/posts/default?max-results=30&start-index=#{30*page+1}"))
    xml = Nokogiri::XML(xml)
    raise EmptyEntry if xml.xpath('//xmlns:entry').empty?
    xml
  end

  # __firstline2title__ :: String -> String
  def self.__firstline2title__(firstline)
    firstline.gsub(/^#*\s*/, '')
  end

  # __title2firstline__ :: String -> String
  def self.__title2firstline__(title)
    '# ' << title.gsub(/#/, '\#')
  end

  # text2xml :: String -> String
  def self.text2xml(text)
    lines = text.lines.to_a
    title = __firstline2title__(lines.shift.strip)
    body = Markdown.new(lines.join).to_html
    # body = body.gsub('&amp;', '&').gsub('&', '&amp;') # For inline HTML Syntax
    <<-EOF.gsub(/^\s*\|/, '')
    |<entry xmlns='http://www.w3.org/2005/Atom'>
    |  <title type='text'>#{title}</title>
    |  <content type='xhtml'>
    |    <div xmlns="http://www.w3.org/1999/xhtml">
    |      #{body}
    |    </div>
    |  </content>
    |</entry>
    EOF
  end

  # html2text :: String -> String
  def self.html2text(html)
    memo = []
    IO.popen('html2markdown', 'r+') {|io|
      io.puts html
      io.close_write
      io.read
    }
  end
end

if __FILE__ == $0
  if ARGV[0] == '--gist'
    Blogger.gist = true
    ARGV.shift
  end

  case ARGV.shift
  when 'list'
    puts (Blogger.list(ARGV[0], 0) + Blogger.list(ARGV[0], 1)).map {|e| "#{e[:title]} -- #{e[:uri]}" }
  when 'show'
    puts Blogger.show(ARGV[0], ARGV[1])
  when 'create'
    uri = Blogger.create(ARGV[0], Blogger.login(ARGV[1], ARGV[2]), STDIN.read)
    if /darwin/ =~ RUBY_PLATFORM
      system "echo '#{uri}' | pbcopy >&/dev/null" rescue nil
    end
    puts uri
  when 'update'
    puts Blogger.update(ARGV[0], ARGV[1], Blogger.login(ARGV[2], ARGV[3]), STDIN.read)
  else
    puts "read README.md"
  end
end
