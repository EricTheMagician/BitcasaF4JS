pth = require 'path'
Future = require('fibers/future')
Fiber = require 'fibers'
wait = Future.wait
fs = require 'fs-extra'
unlink = Future.wrap(fs.unlink)
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

  download: (start,end, cb) ->
    #check to see if part of the file is being downloaded or in use
    file = @
    client = @client
    chunkStart = Math.floor((start)/client.chunkSize) * client.chunkSize
    end = Math.min(end, file.size )
    chunkEnd = Math.min( Math.ceil(end/client.chunkSize) * client.chunkSize, file.size)-1 #and make sure that it's not bigger than the actual file
    nChunks = (chunkEnd - chunkStart)/client.chunkSize
    download = Future.wrap(client.download)
    if nChunks < 1
      Fiber( ->
        fiber = Fiber.current
        while client.downloadTree.has("#{file.bitcasaBasename}-#{chunkStart}")
          fn = ->
            fiber.run()
          setTimeout fn, 100
          Fiber.yield()
        client.downloadTree.set("#{file.bitcasaBasename}-#{chunkStart}", 1)
        client.logger.log "silly", "#{file.name} - (#{start}-#{end})"

        #download chunks
        data = download(client, file.bitcasaPath, file.name, start,end,file.size,true)
        if (chunkEnd - chunkStart) / client.chunkSize <= 1
          BitcasaFile.recursive(client,file, Math.floor(file.size / client.chunkSize) * client.chunkSize, file.size)
        BitcasaFile.recursive(client,file, chunkStart + i * client.chunkSize, chunkEnd + i * client.chunkSize) for i in [1..client.advancedChunks]
        try
          data = data.wait()
        catch error #there might have been a connection error
          data = null
        if data == null
          cb new Buffer(0), 0,0
          return
        client.downloadTree.delete("#{file.bitcasaBasename}-#{chunkStart}")
        cb( data.buffer, data.start, data.end )
        client.logger.log "silly", "after downloading - #{data.buffer.length} - #{data.start} - #{data.end}"
      ).run()
    else if nChunks < 2
      buffer = new Buffer(end-start + 1)
      end1 = chunkStart + client.chunkSize - 1
      start2 = chunkStart + client.chunkSize
      Fiber( ->
        fiber = Fiber.current
        while client.downloadTree.has("#{file.bitcasaBasename}-#{chunkStart}")
          fn = ->
            fiber.run()
          setTimeout fn, 100
          Fiber.yield()
        data1 = download(client, file.bitcasaPath, file.name, start, end1,file.size, true)
        client.downloadTree.set("#{file.bitcasaBasename}-#{chunkStart}", 1)

        while client.downloadTree.has("#{file.bitcasaBasename}-#{chunkStart+client.chunkSize}")
          fn = ->
            fiber.run()
          setTimeout fn, 100
          Fiber.yield()

        data2 = download(client, file.bitcasaPath, file.name, start2, end,file.size, true)
        client.downloadTree.set("#{file.bitcasaBasename}-#{chunkStart+client.chunkSize}", 1)

        try #check that data1 does not have any connection error
          data1 = data1.wait()
        catch error
          data1 = null
        client.downloadTree.delete("#{file.bitcasaBasename}-#{chunkStart}")

        try #check that data1 does not have any connection error
          data2 = data2.wait()
        catch
          data2 = null
        client.downloadTree.delete("#{file.bitcasaBasename}-#{chunkStart+client.chunkSize}", 1)

        if data1 == null or data1.buffer.length == 0
          cb( buffer, 0, 0)
          return
        data1.buffer.copy(buffer,0,data1.start, data1.end)

        if data == null or data2.buffer.length == 0
          cb( buffer, 0, data1.buffer.length )
          return
        data2.buffer.copy(buffer,data1.end - data1.start, data2.start, data2.end)

        cb( buffer, 0, buffer.length )
        return
      ).run()
    else
      client.logger.log("error", "number of chunks greater than 2 - (#{start}-#{end})");
      buffer = new Buffer(0)
      r =
        buffer: buffer
        start: 0
        end: 0
      cb(null, r)

  delete: (cb) ->
    file = @
    Fiber ->
      start = 0
      end = file.client.chunkSize - 1
      while start < file.size
        end = Math.min end, file.size - 1
        location = "#{file.client.downloadLocation}/#{file.bitcasaBasename}-#{start}-#{end}"
        unlink(location).wait()
        start += file.client.chunkSize
        end += file.client.chunkSize

    .run()
    parent = @client.bitcasaTree.get(pth.dirname(@bitcasaPath))
    realPath = pth.join(parent, @name)
    @client.folderTree.delete(realPath)

    parentFolder = @client.folderTree.get( parent )
    idx = parentFolder.children.indexOf @name
    parentFolder.children.splice idx, 1
    @client.deleteFile(@bitcasaPath,cb)
module.exports.file = BitcasaFile
