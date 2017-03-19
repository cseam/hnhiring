require 'nokogiri'
require 'open-uri'
require 'json'
require 'redis'

SPACER = "s.gif"

MONTHS = %w{JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC}

# Used to map from a bad thread to the corresponding good thread for
# the month
EXCEPTIONS = {
  # in this case, 3300371 was posted late by whoishiring, so another
  # poster posted a thread that became the canonical one
  "3300371" => "3300290"
}

# Used for months where a particular thread was simply not posted
ADDITIONS = [
  ["Apr", "2015", "fulltime", "9303396"],
  ["May", "2015", "fulltime", "9471287"],
  ["May", "2015", "freelancers", "9471301"]
]

# HN doesn't like bots, even responsible ones
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_8_2) AppleWebKit/537.17 (KHTML, like Gecko) Chrome/24.0.1309.0 Safari/537.17"

@redis = Redis.new

def handle_time id, s
  if t = @redis.get("hnhiring:comments:#{id}")
    Time.at(t.to_i)
  else
    _, n, unit = s.match(/(\d+) (second|minute|hour|day)s? ago/).to_a
    multiple = {"second" => 1, "minute" => 60, "hour" => 60*60, "day" => 60*60*24}
    time = Time.now - n.to_i * multiple[unit]
    @redis.set("hnhiring:comments:#{id}", time.to_i)
    time
  end
end

def get_comments(id, html="", link=nil)
  sleep 0.5
  if link == nil
    link = "https://news.ycombinator.com/item?id=#{id}"
  end
  more_html_stream = open(link, "User-Agent" => USER_AGENT)
  more_html = more_html_stream.read
  html += more_html
  doc = Nokogiri::HTML(more_html)
  next_link_node = doc.css('a[href*="/x?"]')
  if next_link_node.length > 0
      rel_link = next_link_node.attr('href').value
      link = "https://news.ycombinator.com#{rel_link}"
      get_comments(id, html, link)
  else
      parse_results(id,html)
  end
end

def parse_results(id, html)
  doc = Nokogiri::HTML(html)
  comment_nodes = doc.css(".comment")
  comment_nodes.map{|c|
    submitter, link = c.parent.css("a")
    begin
      cid = link.attr('href').match(/id=(\d+)/)[1]
      time_string = c.parent.css(".comhead")
                    .children.detect{|x| x.text[/second|minute|hour|day/]}.to_s
      time = handle_time cid, time_string
      {
        :id => cid,
        :level => c.parent.parent.css("img[src=\"#{SPACER}\"]").first.attr('width').to_i / 40,
        :html => c.to_s,
        :submitter => submitter.text,
        :url => "https://news.ycombinator.com/#{link.attr('href')}",
        :belongs_to => nil,
        :time => time.to_i
      }
    rescue
    end
  }.compact.reduce([]){|a, c|
    if c[:level] == 0
    elsif c[:level] > a[-1][:level]
      c[:belongs_to] = a[-1][:id]
    elsif c[:level] == a[-1][:level]
      c[:belongs_to] = a[-1][:belongs_to]
    else
      c[:belongs_to] = a.select{|x| x[:level] == c[:level]-1}[-1][:id]
    end
    a << c
  }.reduce({}){|h, c|
    h[c[:id]] = c
    h
  }
end

def get_threads
  html = open('https://news.ycombinator.com/submitted?id=whoishiring', "User-Agent" => USER_AGENT)
  doc = Nokogiri::HTML(html.read)
  threads = doc.css(".title a").map{|x|
    [x.text, x.attr("href").match(/id=(\d+)/)[1]] rescue nil
  }.compact.map{|t|
    date = t[0].match(/\((\w+) (\d+)\)/)
    id = EXCEPTIONS[t[1]] || t[1]
    if date
      if t[0].match(/Seeking freelancer/i)
        [date[1][0..2], date[2], "freelancers", id]
      elsif t[0].match(/Who is Hiring/i)
        [date[1][0..2], date[2], "fulltime", id]
      end
    end
  }.compact + ADDITIONS

  threads.sort_by{|t|
    - (MONTHS.index(t[0].upcase) + t[1].to_i * 100)
  }.map{|t|
    ["#{t[0]} #{t[1]} &mdash; #{t[2]}", t[3]]
  }
end

def load_data
  threads = get_threads
  puts threads.inspect
  comments_by_thread = {}
  threads[0..3].each{|t|
    begin
      comments_by_thread[t[1]] = get_comments(t[1])
      sleep 0.5 # try not to annoy PG
      puts "Loaded #{t[0]}"
    rescue
      puts "Failed on #{t[0]}: #{$!}"
    end
  }
  comments = comments_by_thread
  [threads, comments]
end

if __FILE__ == $0
  threads, comments = load_data
  File.open(ARGV[0] + "/threads.json", "w+"){|f|
    f.write(JSON.dump(threads))
  }
  comments.each{|id, data|
    File.open(ARGV[0] + "/comments-#{id}.json", "w+"){|f|
      f.write(JSON.dump(data))
    }
  }
end
