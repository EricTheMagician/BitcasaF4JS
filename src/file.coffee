pth = require 'path'
Future = require('fibers/future')
Fiber = require 'fibers'
wait = Future.wait
fs = require 'fs-extra'
unlink = Future.wrap(fs.unlink)
#since fs.exists does not return an error, wrap it using an error
_exists = (path, cb) ->
  fs.exists path, (success)->
    cb(null,success)
exists = Future.wrap(_exists)
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
    fn = ->
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
    setImmediate fn
  download: (start,end, cb) ->
    #check to see if part of the file is being downloaded or in use
    file = @
    client = @client
    chunkStart = Math.floor((start)/client.chunkSize) * client.chunkSize
    end = Math.min(end, file.size-1 )
    chunkEnd = Math.min( Math.ceil(end/client.chunkSize) * client.chunkSize, file.size)-1 #and make sure that it's not bigger than the actual file
    nChunks = (chunkEnd - chunkStart)/client.chunkSize
    _download = (_cb) ->
      #wait for event emitting if downloading
      #otherwise, just read the file if it exists
      exist = exists(pth.join(client.downloadLocation, "#{file.bitcasaBasename}-#{chunkStart}-#{chunkEnd}")).wait()
      if not exist
        if not client.downloadTree.has("#{file.bitcasaBasename}-#{chunkStart}")
          client.downloadTree.set("#{file.bitcasaBasename}-#{chunkStart}", 1)
          data = client.download(client, file.bitcasaPath, file.name, start,end,file.size,true, ->)
        client.ee.once "#{file.bitcasaBasename}-#{chunkStart}", (err, data) ->
          client.downloadTree.delete("#{file.bitcasaBasename}-#{chunkStart}")
          data.start -= chunkStart
          data.end -= chunkStart
          _cb(err, data)

      else
        client.download(client, file.bitcasaPath, file.name, start,end,file.size,true,_cb)

    download = Future.wrap(_download)
    if nChunks < 1
      Fiber( ->
        fiber = Fiber.current
        fiberRun = ->
          fiber.run()
          return null

        client.logger.log "silly", "#{file.name} - (#{start}-#{end})"

        #download chunks
        data = download()
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
      end1 = chunkStart + client.chunkSize - 1
      start2 = chunkStart + client.chunkSize

      Fiber( ->
        fiber = Fiber.current
        fiberRun = ->
          fiber.run()
          return null

        while client.downloadTree.has("#{file.bitcasaBasename}-#{chunkStart}")
          setImmediate fiberRun
          Fiber.yield()
        data1 = download(client, file.bitcasaPath, file.name, start, end1,file.size, true)
        client.downloadTree.set("#{file.bitcasaBasename}-#{chunkStart}", 1)

        while client.downloadTree.has("#{file.bitcasaBasename}-#{chunkStart+client.chunkSize}")
          setImmediate fiberRun
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
          cb( new Buffer(0), 0, 0)
          return
        buffer1 = data1.buffer.slice(data1.start, data1.end)

        if data2 == null or data2.buffer.length == 0
          #since buffer1 is still good, just return that
          cb( buffer1, 0, data1.buffer.length )
          return
        buffer2 = data2.buffer.slice(data2.start, data2.end)

        buffer = Buffer.concat([buffer1, buffer2])
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
