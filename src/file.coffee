pth = require 'path'
Future = require('fibers/future')
Fiber = require 'fibers'
wait = Future.wait

class BitcasaFile
  @fileAttr: 0o100777 #according to filesystem information, the 15th bit is set and the read and write are available for everyone
  constructor: (@client,@bitcasaPath, @name, @size, @ctime, @mtime) ->
    @bitcasaBasename = pth.basename @bitcasaPath


  getAttr: (cb)->
    attr =
      mode: BitcasaFile.fileAttr,
      size: @size,
      nlink: 1,
      mtime: @mtime,
      ctime: @ctime
    cb(0,attr)

  download: (start,end, cb) ->
    #check to see if part of the file is being downloaded or in use
    file = @
    client = @client
    chunkStart = Math.floor((start)/client.chunkSize) * client.chunkSize
    end = Math.min(end, file.size )
    chunkEnd = Math.min( Math.ceil(end/client.chunkSize) * client.chunkSize, file.size)-1 #and make sure that it's not bigger than the actual file
    Fiber( ->
      while client.downloadTree.has("#{file.bitcasaBasename}-#{chunkStart}")
      fiber = Fiber.current
        fn = ->
          fiber.run()
        setTimeout fn, 50
        Fiber.yield()
      client.downloadTree.set("#{file.bitcasaBasename}-#{chunkStart}", 1)
      download = Future.wrap(client.download)
      client.logger.log "silly", "#{file.name} - (#{start}-#{end})"
      data = download(client, file.bitcasaPath, file.name, start,end,file.size,true).wait()
      client.logger.log "silly", "after downloading - #{data.buffer.length} - #{data.start} - #{data.end}"
      client.downloadTree.delete("#{file.bitcasaBasename}-#{chunkStart}")
      cb( data.buffer, data.start, data.end )
    ).run()
module.exports.file = BitcasaFile
