# Copyright (C) 2024 Mark D. Blackwell. All rights reserved. This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

require 'date'
require 'json'
require 'net/http'
require 'open-uri'

module ReportSystem
  module Artists
    extend self

    attr_reader :artists

    Artist = ::Data.define :artist

    @artists = ::Hash.new 0

    def build
      Songs.songs.each_pair { |key, count| @artists[Artist.new key.artist] += count }
      nil
    end
  end

  module Database
    extend self

    def artists_alphabetized
       @artists_alphabetized ||= begin
        artists = Artists.artists
        keys_sorted = artists.keys.sort do |a, b|
          [a.artist.upcase, artists[a]] <=> [b.artist.upcase, artists[b]]
        end
        keys_sorted.map { |key| [key, artists[key]] }
      end
    end

    def artists_by_popularity
       @artists_by_popularity ||= begin
        artists = Artists.artists
        keys_sorted = artists.keys.sort do |a, b|
          unless artists[a] == artists[b]
            artists[b] <=> artists[a]
          else
            a.artist.upcase <=> b.artist.upcase
          end
        end
        keys_sorted.map { |key| [key, artists[key]] }
      end
    end

    def ips_alphabetized
       @ips_alphabetized ||= begin
        ips = Ips.ips
        keys_sorted = ips.keys.sort do |a, b|
          [a.ip, ips[a]] <=> [b.ip, ips[b]]
        end
        keys_sorted.map { |key| [key, ips[key]] }
      end
    end

    def ips_by_frequency
       @ips_by_frequency ||= begin
        ips = Ips.ips
        keys_sorted = ips.keys.sort do |a, b|
          unless ips[a] == ips[b]
            ips[b] <=> ips[a]
          else
            a.ip <=> b.ip
          end
        end
        keys_sorted.map { |key| [key, ips[key]] }
      end
    end

    def likes_count
       @likes_count ||= Records.records.select { |e| :l == e.toggle }.length
    end

    def locations_by_frequency
       @locations_by_frequency ||= begin
        locations = Locations.locations
        keys_sorted = locations.keys.sort do |a, b|
          unless locations[a] == locations[b]
            locations[b] <=> locations[a]
          else
            [    a.city, a.region_name, a.country, a.continent, a.isp] <=>
                [b.city, b.region_name, b.country, b.continent, b.isp]
          end
        end
        keys_sorted.map { |key| [key, locations[key]] }
      end
    end

    def songs_alphabetized_by_artist
       @songs_alphabetized_by_artist ||= begin
        songs = Songs.songs
        keys_sorted = songs.keys.sort do |a, b|
          [    a.artist.upcase, a.title.upcase, songs[a]] <=>
              [b.artist.upcase, b.title.upcase, songs[b]]
        end
        keys_sorted.map { |key| [key, songs[key]] }
      end
    end

    def songs_by_popularity
       @songs_by_popularity ||= begin
        songs = Songs.songs
        keys_sorted = songs.keys.sort do |a, b|
          unless songs[a] == songs[b]
            songs[b] <=> songs[a]
          else
            [    a.artist.upcase, a.title.upcase] <=>
                [b.artist.upcase, b.title.upcase]
          end
        end
        keys_sorted.map { |key| [key, songs[key]] }
      end
    end

    def unlikes_count
       @unlikes_count ||= Records.records.select { |e| :u == e.toggle }.length
    end
  end

  module Ips
    extend self

    attr_reader :ips

    Ip = ::Data.define :ip

    @ips = ::Hash.new 0

    def build
      Records.records.each do |record|
        key = Ip.new record.ip.downcase
        @ips[key] += 1
      end
      nil
    end
  end

  module Locations
    extend self

    BATCH_LENGTH_MAX = 100
    ENDPOINT = ::URI::HTTP.build host: 'ip-api.com', path: '/batch', query: 'fields=city,continent,country,isp,message,query,regionName,status'
    HEADERS = {Accept: 'application/json', Connection: 'Keep-Alive', 'Content-Type': 'application/json'}

    attr_reader :locations

    Location = ::Data.define :city, :continent, :country, :isp, :region_name

    @locations = ::Hash.new 0

    def build
      requests_remaining, seconds_till_next_window = [15, 60]
      a = Database.ips_alphabetized
      a.each_slice BATCH_LENGTH_MAX do |batch|
        keys, counts = batch.transpose
        delay requests_remaining, seconds_till_next_window
        begin
          response = service_fetch keys, counts
          add response, counts
          requests_remaining, seconds_till_next_window = timings response
        rescue
          $stderr.puts "Rescued #{response.inspect}"
        end
      end
      nil
    end

    private

    def add(response, counts)
      ::JSON.parse(response.body).each_with_index do |ip_data, index|
        status = ip_data['status']
#       $stderr.puts "#{ip_data.inspect}"
        unless 'success' == status
          $stderr.puts "status: #{status}, message: #{ip_data['message']}, query: #{ip_data['query']}"
          next
        end
        fields = %w[city continent country isp regionName].map { |e| ip_data[e].to_sym }
        @locations[Location.new(*fields)] += counts.at index
      end
      nil
    end

    def delay(requests_remaining, seconds_till_next_window)
      seconds = requests_remaining.positive? ? 0 : seconds_till_next_window.succ
      ::Kernel.sleep seconds
      nil
    end

    def service_fetch(keys, counts)
      ips = keys.map &:ip
      data = ::JSON.generate ips
# Within an HTTP session, is it possible to post to a URI which includes a query? I couldn't discover how.
## ::Net::HTTP.start(hostname) do |http|
      result = ::Net::HTTP.post ENDPOINT, data, HEADERS
      $stderr.puts "#{result.inspect}" unless ::Net::HTTPOK == result.class
      result
    end

    def timings(response)
      %w[rl ttl].map { |e| "x-#{e}" }.map { |k| response.to_hash[k].first.to_i }
    end
  end

  module Main
    extend self

    FILENAME_OUT = 'var/song-likes-report-first.txt'

    FIRST = begin
      argument = ::ARGV[0]
      message = 'The first command-line argument must be a valid date.'
      ::Kernel.abort message unless argument
      ::Date.parse argument
    end

    LAST = begin
      yesterday = ::Date.today - 1
      argument = ::ARGV[1]
      argument ? (::Date.parse argument) : yesterday
    end

    def run
      $stdout = ::File.open FILENAME_OUT, 'w'
      s = ::Time.now.strftime '%Y-%b-%d %H:%M:%S'
      print "WTMD Song Likes Report, run #{s}.\n\n"
      puts "Range of dates: #{FIRST} through #{LAST} (inclusive)."
      Window.define FIRST, LAST
      Records.transcribe
      Songs.build
      Artists.build
      Ips.build
      Locations.build
      Report.print_report
      nil
    end
  end

  module Records
    extend self

    attr_reader :records

# The matched fields are: time, ip, toggle, artist, and title.
#                              time       ip         toggle       artist          title
    REGEXP = ::Regexp.new(/^ *+([^ ]++) ++([^ ]++) ++([lu]) ++" *+(.*?) *+" ++" *+(.*?) *+" *+$/n)

    TIME_INDEX = 1
    URI_IN = 'https://wtmd.org/like/like.txt'

# Depends on previous:
    LINES = ::URI.open(URI_IN) { |f| f.readlines }

    Record = ::Data.define :time, :ip, :toggle, :artist, :title

    @records = []

    def transcribe
      lines_count_within = 0
      lines_count_bad = 0

      LINES.map do |line|
        md = REGEXP.match line
        unless md
          lines_count_bad += 1
          next 
        end
        fields = 5.times.map { |i| md[i.succ].to_sym }
        if Window.within? md[TIME_INDEX]
          lines_count_within += 1
          @records.push Record.new(*fields)
        end
      end
      message = "Warning: #{lines_count_bad} interaction records were bad.\n"
      $stderr.puts message if lines_count_bad > 0
      puts "#{LINES.length} total customer interactions read; and within the selected range of dates:"
      puts "#{lines_count_within} interactions found, comprising"
# The Report module prints next.
      nil
    end
  end

  module Report
    extend self

    OUT_SECOND = ::File.open 'var/song-likes-report-second.txt', 'w'
    OUT_THIRD = ::File.open 'var/song-likes-report-third.txt', 'w'

    def print_report
      print_summary
      print_popularity
      print_alphabetical
      print_locations
      nil
    end

    private

    def print_alphabetical
      OUT_SECOND.puts "Songs (alphabetical by artist):\n\n"
      a = Database.songs_alphabetized_by_artist
      OUT_SECOND.puts a.map { |key, count| "#{count} : #{key.title} : #{key.artist}" }

      OUT_SECOND.puts "\nArtists (alphabetical):\n\n"
      a = Database.artists_alphabetized
      OUT_SECOND.puts a.map { |key, count| "#{count} : #{key.artist}" }
      nil
    end

    def print_locations
# Temporarily, for development, report the IPs:
      OUT_THIRD.puts "( IPs by frequency ):\n\n"
      a = Database.ips_by_frequency
      OUT_THIRD.puts a.map { |key, count| "( #{count} : #{key.ip} )" }
      OUT_THIRD.puts ""

# Report the locations:
      OUT_THIRD.puts "Locations (by frequency):\n\n"
      a = Database.locations_by_frequency
      lines = a.map do |k, count|
        fields = [k.city, k.region_name, k.country, k.continent]
        "#{count} : #{fields.join ', '} – (#{k.isp})"
      end
      OUT_THIRD.puts lines
    end

    def print_popularity
      puts "\nSong popularity:\n\n"
      a = Database.songs_by_popularity
      puts a.map { |key, count| "#{count} : #{key.title} : #{key.artist}" }

      puts "\nArtist popularity:\n\n"
      a = Database.artists_by_popularity
      puts a.map { |key, count| "#{count} : #{key.artist}" }
      nil
    end

    def print_summary
      print "#{Database.likes_count} likes and "
      puts "#{Database.unlikes_count} unlikes from"
      print "#{Locations.locations.length} locations "
      puts "(#{Ips.ips.length} IPs),"
      puts "#{Artists.artists.length} artists and"
      puts "#{Songs.songs.length} songs."
      nil
    end
  end

  module Songs
    extend self

    attr_reader :songs

    Song = ::Data.define :artist, :title

    @raw = ::Hash.new 0

    def build
      Records.records.each { |e| add(e.artist, e.title, e.toggle) }
      @songs = filter
      @raw = nil
      nil
    end

    private

    def add(artist, title, toggle)
      addend = :l == toggle ? 1 : -1
      @raw[Song.new artist, title] += addend
      nil
    end

    def filter
      @raw.reject do |key, count|
        all_empty = key.artist.empty? && key.title.empty?
# An Unlike in our window may be paired with a Like prior to it.
        all_empty || count <= 0
      end
    end
  end

  module Window
    extend self

    def define(*parms)
      @beginning, @ending = parms
      nil
    end

    def within?(date_raw)
      date = ::Date.iso8601 date_raw
      date >= @beginning &&
          date <= @ending
    end
  end
end

::ReportSystem::Main.run
