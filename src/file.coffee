pth = require 'path'
Future = require('fibers/future')
Fiber = require 'fibers'
wait = Future.wait
fs = require 'fs'
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

  @recursive:  (client,file,rStart, rEnd) ->
    rEnd = Math.min( Math.ceil(rEnd/client.chunkSize) * client.chunkSize, file.size)-1
    baseName = pth.basename file.bitcasaPath
    if (rEnd + 1) <= file.size and rEnd > rStart
      parentPath = client.bitcasaTree.get(pth.dirname(file.bitcasaPath))
      filePath = pth.join(parentPath,file.name)
      cache = pth.join(client.cacheLocation,"#{baseName}-#{rStart}-#{rEnd-1}")
      unless fs.existsSync(cache)
        unless client.downloadTree.has("#{baseName}-#{rStart}")
          client.logger.log("silly", "#{baseName}-#{rStart}-#{rEnd - 1} -- has: #{client.downloadTree.has("#{filePath}-#{rStart}")} - recursing with - (#{rStart}-#{rEnd})")
          client.downloadTree.set("#{baseName}-#{rStart}",1)
          _callback = (err, data) ->
            client.downloadTree.delete("#{baseName}-#{rStart}")
          client.download(client, file.bitcasaPath, file.name, rStart,rEnd,file.size, false, _callback )

  # if recurse
  #   #download the last chunk in advance
  #   maxStart = Math.floor( maxSize / client.chunkSize) * client.chunkSize
  #   recursive maxStart, maxSize
  #   #download the next few chunks in advance
  #   recursive(chunkStart + num*client.chunkSize, chunkEnd + 1 + num*client.chunkSize)  for num in [1..client.advancedChunks]


  download: (start,end, cb) ->
    #check to see if part of the file is being downloaded or in use
    file = @
    client = @client
    chunkStart = Math.floor((start)/client.chunkSize) * client.chunkSize
    end = Math.min(end, file.size )
    chunkEnd = Math.min( Math.ceil(end/client.chunkSize) * client.chunkSize, file.size)-1 #and make sure that it's not bigger than the actual file

    Fiber( ->
      fiber = Fiber.current
      while client.downloadTree.has("#{file.bitcasaBasename}-#{chunkStart}")
        fn = ->
          fiber.run()
        setTimeout fn, 50
        Fiber.yield()
      client.downloadTree.set("#{file.bitcasaBasename}-#{chunkStart}", 1)
      download = Future.wrap(client.download)
      client.logger.log "silly", "#{file.name} - (#{start}-#{end})"

      #download chunks
      data = download(client, file.bitcasaPath, file.name, start,end,file.size,true)
      BitcasaFile.recursive(client,file, Math.floor(file.size / client.chunkSize) * client.chunkSize, file.size)
      BitcasaFile.recursive(client,file, chunkStart + i * client.chunkSize, chunkEnd + i * client.chunkSize) for i in [1..client.advancedChunks]
      data = data.wait()
      client.logger.log "silly", "after downloading - #{data.buffer.length} - #{data.start} - #{data.end}"
      client.downloadTree.delete("#{file.bitcasaBasename}-#{chunkStart}")
      cb( data.buffer, data.start, data.end )
    ).run()
module.exports.file = BitcasaFile
