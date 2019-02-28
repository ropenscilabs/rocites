require 'date'
require 'time'
require 'twitter'
require 'faraday'
require 'aws/s3'
require 'csv'
require 'uuid'
require 'multi_json'
require 'uri'
require 'anystyle'

# twitter setup
$twitclient = Twitter::REST::Client.new do |config|
  config.consumer_key        = ENV["ROCITES_TWITTER_CONSUMER_KEY"]
  config.consumer_secret     = ENV["ROCITES_TWITTER_CONSUMER_SECRET"]
  config.access_token        = ENV["ROCITES_TWITTER_ACCESS_TOKEN"]
  config.access_token_secret = ENV["ROCITES_TWITTER_ACCESS_SECRET"]
end

# aws setup
$s3 = AWS::S3::Base.establish_connection!(
  :access_key_id     => ENV["AWS_S3_WRITE_ACCESS_KEY"], 
  :secret_access_key => ENV["AWS_S3_WRITE_SECRET_KEY"]
)

module Rocites
  def self.clean_desc2(y)
    y = y.gsub(/\n/, ' ')
    y.match(/^.{0,280}\b/)[0]
  end

  def self.tweet(x)
    puts 'sending tweet for "' + x["name"] + '"'

    if x["doi"].nil?
      url = URI.extract(x["citation"], ['http', 'https']).keep_if { |x| x.match(/https?/) }
      if url.empty?
        ""
      else
        url = url[0]
      end
    else
      url = "https://doi.org/" + x["doi"].delete('\\"')
    end

    # authors
    # x={"citation"=>"Amano, T., Lamming, J. D. L., & Sutherland, W. J. (2016). Spatial Gaps in Global Biodiversity Information and the Role of Citizen Science. BioScience, 66(5), 393–400. doi:10.1093/biosci/biw022"}
    # x={"citation"=>"Wheeler, D. L., Scott, J., Dung, J. K. S., & Johnson, D. A. (2019). Evidence of a trans-kingdom plant disease complex between a fungus and plant-parasitic nematodes. PLOS ONE, 14(2), e0211508. <https://doi.org/10.1371/journal.pone.0211508>"}
    # cit = x['citation']
    tmp_auth = AnyStyle.parse x["citation"]
    auths = tmp_auth[0][:author]
    if auths.length > 2
      authors = auths[0][:family].capitalize + " et al."
    elsif auths.length == 2
      authors = auths.map { |z| z[:family].capitalize }.join(" & ")
    else
      authors = auths[0][:family].capitalize
    end

    # handle if > 1 pkg name
    if !x['name'].match(/,/).nil?
      # plural
      nm = "📦's " + x['name'].split(',').map{|w| "#" + w}.join(" ")
    else
      # singular
      nm = "📦 " + "#" + x['name']
    end

    # mentions
    pkghandconn = Faraday.new(:url => 'https://raw.githubusercontent.com/ropensci/roapi/master/data/package_handle_mapping.csv') do |f|
      f.adapter Faraday.default_adapter
    end
    pkghand = pkghandconn.get;
    pkghand.body.force_encoding(Encoding::UTF_8);
    csv = CSV.parse(pkghand.body, :col_sep => ",", :quote_char => "|", :headers => true);
    pkg_handle_hsh = csv.map {|a| Hash[ a ] };
    pkgs = x['name'].split(',')
    pkg_handle_res = pkg_handle_hsh.select { |z| pkgs.include?(z['package']) }
    if pkg_handle_res.length != 0
      handles = pkg_handle_res.map{ |x| "@" + x["handle"] }.join(" ")
      handles = handles.length > 0 ? "| cc " + handles : ""
    end

    # research snippet
    res_snip = x['research_snippet']
    if res_snip.nil?
      res_snip = "in their research"
    else
      res_snip = "in their work on " + res_snip
    end

    # image path
    image_remote_path = File.basename(x['img_path'])
    # eg image full URL
    # https://raw.githubusercontent.com/ropensci/roapi/master/data/img/AielloEtal2019JournalOfNeurology.png
    if !image_remote_path.nil?
      image_remote_url = 
        "https://raw.githubusercontent.com/ropensci/roapi/master/data/img/" +
        image_remote_path
      image_d = Faraday.new(:url => image_remote_url) do |f|
        f.adapter Faraday.default_adapter
      end
      image_res = image_d.get;
      File.open(image_remote_path, 'wb') { |fp| fp.write(image_res.body) }
      # File.open(image_remote_path, 'wb') { |fp| fp.write(image_res.body) }
    end

    # build tweet
    tweet = "New @rOpenSci citation: %s used #rstats %s %s %s %s" %
      [authors, nm, res_snip, url, handles]
    tweet = clean_desc2(tweet)

    # if tweet already sent, skip
    mytweets = $twitclient.user_timeline;
    logg = []
    mytweets.each do |z|
      logg << tweet.casecmp(z.text) == 0
    end
    if logg.include?(0)
      puts 'skipping, tweet already sent'
    else
      # not sent, sending it
      puts 'new citation for %s, sending tweet' % x["name"]
      if image_remote_path.nil?
        $twitclient.update(tweet)
      else
        $twitclient.update_with_media(tweet, File.new(image_remote_path))
        puts 'deleting file %s' % image_remote_path
        File.delete(image_remote_path)
      end
    end
  end

  # upload x hashes to S3
  def self.upload_s3(x)
    x.each do |i|
      AWS::S3::S3Object.store(UUID.generate + ".json", i.to_json, "rocites")
    end
  end

  # download all objects in the rocites S3 bucket, convert to array of hashes
  def self.download_s3
    x = AWS::S3::Bucket.find('rocites')
    all_hashes = x.map { |w| MultiJson.load(w.value.to_s) }
    return all_hashes
  end

  # get ropensci/roapi citations.tsv file, convert to array of hashes
  def self.get_citations
    conn = Faraday.new(:url => 'https://raw.githubusercontent.com/ropensci/roapi/master/data/citations.tsv') do |f|
      f.adapter Faraday.default_adapter
    end
    x = conn.get;
    x.body.force_encoding(Encoding::UTF_8);
    tsv = CSV.parse(x.body, :col_sep => "\t", :headers => true);
    hsh = tsv.map {|a| Hash[ a ] };
    # convert NA's to nil's
    hsh = hsh.map { |a| a.each { |k,v| a[k] = v == "NA" ? nil : v }  };
    return hsh
  end

  # get new citations, if any
  def self.new_citations
    puts "getting citations from github"
    ctz = self.get_citations;
    puts "getting cached citations on s3"
    s3dat = self.download_s3;

    # compare
    diffed = ctz - s3dat;
    diffeds3 = Marshal.load(Marshal.dump(diffed));

    # check for any that have many pkgs for 1 citations & combine 
    cites = diffed.map { |e| e['citation'] };
    notrep = []
    if cites.uniq.length != cites.length
      # the repeated citation
      repcit = cites.detect {|e| cites.count(e) > 1}
      reps = diffed.select { |e| e['citation'] == repcit }
      pkgnames = reps.map { |e| e['name'] }
      reps[0]['name'] = pkgnames.join(',')
      # combine the two
      notrep = diffed.select { |e| e['citation'] != repcit }
      notrep.append(reps[0])
    else
      notrep = diffeds3
    end

    # return any new, nil if no new ones
    if notrep.empty?
      return nil
    else 
      # upload to s3
      puts "uploading new citations to s3"
      self.upload_s3(diffeds3)
      # return for tweeting
      return notrep
    end
  end

end
