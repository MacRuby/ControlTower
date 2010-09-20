framework 'Foundation'
require 'rack'

class PhotoSearch
  RESPONSE_TEMPLATE =<<-RESPONSE
    <!DOCTYPE HTML>
    <html>
      <head><title>%s is for...</title></head>
      <body style='background-color:#CCFFFF; margin:5%%; padding:5%%'>
        <h1><b>%s</b> is for:</h1>
        <p>%s<img src='%s' style='text-align:center;max-width:600px;max-height:400px;'></p>
      </body>
    </html>
  RESPONSE

  PICASA_URL_TEMPLATE = "http://picasaweb.google.com/data/feed/api/all?q=%s&max-results=%i"

  def build_response(letter, photo)
    summary = photo.nodesForXPath("./summary", error:nil).first.stringValue
    src = photo.nodesForXPath("./media:group/media:content/@url", error:nil).first.stringValue
    RESPONSE_TEMPLATE % [letter, letter, summary, src]
  end

  def get_photo(letter, max_results=10)
    return "Must provide a letter" unless letter
    return "No results found in the first 200 results" if max_results > 200
    url = NSURL.URLWithString(PICASA_URL_TEMPLATE % [Rack::Utils.escape(letter), max_results])
    xmlDoc = NSXMLDocument.alloc.initWithContentsOfURL(url, options:NSXMLDocumentTidyXML, error:nil)

    entries = xmlDoc.nodesForXPath("//entry", error:nil)
    entries.each do |entry|
      summary = entry.nodesForXPath("./summary", error:nil)[0].stringValue
      if summary[0] == letter
        return build_response(letter, entry)
      end
    end
    get_photo(letter, max_results+=10)
  end

  def call(env)
    letter_to_search = Rack::Utils.unescape(env['QUERY_STRING']).chars.first
    [200, { 'Content-Type' => 'text/html; charset=UTF-8' }, get_photo(letter_to_search)]
  end


end

run PhotoSearch.new
