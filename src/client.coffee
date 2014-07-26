BASEURL = 'https://developer.api.bitcasa.com/v1/'
RateLimiter = require('limiter').RateLimiter
Client = require('node-rest-client').Client;
dict = require 'dict'
pth = require 'path'
fs = require 'fs'
memoize = require 'memoizee'
d = require('d');

memoizeMethods = require('memoizee/methods')

#for mocha testing
if Object.keys( module.exports ).length == 0
  r = require './folder.coffee'
  BitcasaFolder = r.folder
else
  BitcasaFolder = module.exports.folder

existsMemoized = memoize(fs.existsSync, {maxAge:5000})
class BitcasaClient
  constructor: (@id, @secret, @redirectUrl, @logger, @accessToken = null, @chunkSize = 1024*1024, @advancedChunks = 10, @cacheLocation = '/tmp/node-bitcasa') ->
    @rateLimit = new RateLimiter 175, 'minute'
    now = (new Date).getTime()
    root = new BitcasaFolder(@,'/', 'root', now, now, [])
    @folderTree = new dict({'/': root})
    @bitcasaTree = new dict({'/': '/'})
    @downloadTree = new dict()
    if @accessToken != null
      @setRest()

    client = @;
    fs.exists @cacheLocation, (exists) ->
      if !exists
        fs.mkdirSync(client.cacheLocation)

  setRest: ->
    @client = new Client
    @client.registerMethod 'getRootFolder', "#{BASEURL}folders/?access_token=#{@accessToken}", "GET"
    @client.registerMethod 'downloadChunk', "#{BASEURL}files/name.ext?path=${path}&access_token=#{@accessToken}", "GET"
    @client.registerMethod 'getFolder', url = "#{BASEURL}/folders${path}?access_token=#{@accessToken}", "GET"

    @client.on 'error', (err) ->
      console.log('There was an error connecting with bitcasa:', err)

  loginUrl: ->
    "#{BASEURL}oauth2/authenticate?client_id=#{@id}&redirect_url=#{@redirectUrl}"

  authenticate: (code) ->
    url = "#{BASEURL}oauth2/access_token?secret=#{@secret}&code=#{code}"
    new Error("Not implemented")

  # callback should take 3 parameters:
  #   a buffer, where to start and where to end.
  #   the buffer is where the data is located
  download: (path, name, start,end,maxSize, recurse, cb ) ->
    client = @
    #round the amount of bytes to be downloaded to multiple chunks
    chunkStart = Math.floor((start)/client.chunkSize) * client.chunkSize
    end = Math.min(end,maxSize)
    chunkEnd = Math.min( Math.ceil(end/client.chunkSize) * client.chunkSize, maxSize)-1 #and make sure that it's not bigger than the actual file

    chunks = (chunkEnd - chunkStart)/client.chunkSize
    if chunks > 1 and (maxSize - start) > 65536
      client.logger.log("debug", "number chunks requested greater than 1 - (start,end) = (#{start}-#{end})")
      client.logger.log("debug", "number chunks requested greater than 1 - (chunkStart,chunkEnd) = (#{chunkStart}-#{chunkEnd})")

    #save location
    location = pth.join(client.cacheLocation,"#{pth.basename(path)}-#{chunkStart}-#{chunkEnd}")
    client.logger.log('silly',"cache location: #{location}")

    recursive = (rStart, rEnd) ->
      rEnd = Math.min( Math.ceil(rEnd/client.chunkSize) * client.chunkSize, maxSize)-1
      if (rEnd + 1) <= maxSize and rEnd > rStart
        parentPath = client.bitcasaTree.get(pth.dirname(path))
        filePath = pth.join(parentPath,name)
        cache = pth.join(client.cacheLocation,"#{pth.basename(path)}-#{rStart}-#{rEnd-1}")
        unless existsMemoized(cache)
          unless client.downloadTree.has("#{filePath}-#{rStart}")
            client.logger.log("silly", "#{filePath}-#{rStart}-#{rEnd - 1} -- exists: - #{existsMemoized("#{filePath}-#{rStart}")} - has: #{client.downloadTree.has("#{filePath}-#{rStart}")} - recursing at #{chunkStart} - (#{rStart}-#{rEnd})")
            client.downloadTree.set("#{filePath}-#{rStart}",1)
            callback = ->
                client.downloadTree.delete("#{filePath}-#{rStart}")
            client.download(path, name, rStart,rEnd,maxSize, false, callback )

    #check if the data has been cached or not
    #otherwise, download from the web
    if fs.existsSync(location)
      readSize = end - start;
      buffer = new Buffer(readSize+1)
      fd = fs.openSync(location,'r')
      bytesRead = fs.readSync(fd,buffer,0,readSize+1, start-chunkStart)
      fs.closeSync(fd)
      cb(buffer, 0, readSize+1)
    else
      client.logger.log("info", "#{name} - downloading #{chunkStart}-#{chunkEnd}")
      if @rateLimit.tryRemoveTokens(1)
          args =
            "path":
              "path": path
            headers:
              Range: "bytes=#{chunkStart}-#{chunkEnd}"
          console.log "download requests: #{client.rateLimit.getTokensRemaining()}"
          callback = (data,response) ->
            client.logger.log("debug", "downloaded: #{location} - #{chunkEnd-chunkStart} -- limit #{client.rateLimit.getTokensRemaining()}")
            if data.length == 14 and data.toString() == "invalid range"
              client.logger.log("debug", "failed to download #{location} -- invalid range")
              client.download(path, name, start,end,maxSize, recurse, cb )
            else if not (data instanceof Buffer)
              client.logger.log("debug", "failed to download #{location} -- typeof data: #{typeof data} -- length #{data.length} -- invalid type")
              client.download(path, name, start,end,maxSize, recurse, cb )
            else if  data.length < (chunkStart - chunkEnd + 1)
              client.logger.log("debug", "failed to download #{location} -- #{data.length} - size mismatch")
              client.download(path, name, start,end,maxSize, recurse, cb )
            else
              client.logger.log("debug", "successfully to download #{location}")
              fs.writeFileSync(location,data)
              cb(data, start - chunkStart, end+1 - chunkStart )
          client.logger.log "debug", "starting to download #{location}"
          req = client.client.methods.downloadChunk args,callback
          req.on 'error', (err) ->
            console.log "there was an error with request #{location}, #{err}"
      else
        fn =->
          client.download(path, name, start,end,maxSize, recurse, cb )
        setTimeout(fn, 5000)
    if recurse
      #download the last chunk in advance
      maxStart = Math.floor( maxSize / client.chunkSize) * client.chunkSize
      recursive maxStart, maxSize
      #download the next few chunks in advance
      recursive(chunkStart + num*client.chunkSize, chunkEnd + 1 + num*client.chunkSize)  for num in [1..client.advancedChunks]
Object.defineProperties(BitcasaClient.prototype, memoizeMethods({
  getFolders: d( (path,cb)->
    client = @
    object = client.folderTree.get(path)
    if object instanceof BitcasaFolder
      console.log "requests: #{client.rateLimit.getTokensRemaining()}"
      if @rateLimit.tryRemoveTokens(1)
        callback = (data,response) ->
          BitcasaFolder.parseFolder(data,response, client,null, cb)
        depth = 3
        if path == "/"
          depth = 1
        client.logger.log("debug", "getting folder info from bitcasa for #{path} -- depth #{depth}")
        url = "#{BASEURL}/folders#{object.bitcasaPath}?access_token=#{client.accessToken}&depth=#{depth}"
        client.client.get(url, callback)
      else
        client.logger.log("remaining requests too low: #{client.rateLimit.getTokensRemaining()}" )

  , { maxAge: 120000, length: 1 })
}));
module.exports.client = BitcasaClient
