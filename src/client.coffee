BASEURL = 'https://developer.api.bitcasa.com/v1/'
RateLimiter = require('limiter').RateLimiter
Client = require('node-rest-client').Client;
dict = require 'dict'
pth = require 'path'
fs = require 'fs-extra'
memoize = require 'memoizee'
d = require('d');
Future = require('fibers/future')
Fiber = require 'fibers'
wait = Future.wait

#for mocha testing
if Object.keys( module.exports ).length == 0
  r = require './folder.coffee'
  BitcasaFolder = r.folder

  r = require './file.coffee'
  BitcasaFile = r.file

else
  BitcasaFolder = module.exports.folder
  BitcasaFile = module.exports.file


#these libraries are required for file upload
rest = require 'restler'
mmm = require('mmmagic')
Magic = mmm.Magic
magic = new Magic(mmm.MAGIC_MIME_TYPE)

#wrap async fs methods to sync mode using fibers
writeFile = Future.wrap(fs.writeFile)
open = Future.wrap(fs.open)
read = Future.wrap(fs.read)
#since fs.exists does not return an error, wrap it using an error
_exists = (path, cb) ->
  fs.exists path, (success)->
    cb(null,success)
exists = Future.wrap(_exists)

_close = (path,cb) ->
  fs.close path, (err) ->
    cb(err, true)
close = Future.wrap(_close)
stats = Future.wrap(fs.stat)


#wrap mime type detection with fibers
f = (file, cb) ->
  magic.detectFile file, (err, res) ->
    cb(err,res)
detectFile = Future.wrap(f)

#wrap get folder
_getFolder = (client, path, depth, cb) ->
  args =
    path:
      path: path
      depth: depth
      timeout: 120000
  returned = false

  #if not done after 5 minutes, we have a problem
  callback = ->
    if not returned
      returned = true
      cb("taking too long to getFolder")
  timeout = setTimeout callback, 300000

  req = client.client.methods.getFolder args, (data, response) ->
    if not returned
      returned = true
      clearTimeout timeout
      cb(null, data)

  req.on 'error', (err) ->
    if not returned
      returned = true
      clearTimeout timeout
      cb(err)


getFolder = Future.wrap(_getFolder)


memoizeMethods = require('memoizee/methods')
existsMemoized = memoize(fs.existsSync, {maxAge:5000})
class BitcasaClient
  constructor: (@id, @secret, @redirectUrl, @logger, @accessToken = null, @chunkSize = 1024*1024, @advancedChunks = 10, @cacheLocation = '/tmp/node-bitcasa') ->
    @rateLimit = new RateLimiter 175, 'minute'
    now = (new Date)
    root = new BitcasaFolder(@,'/', '', now, now, [])
    @folderTree = new dict({'/': root})
    @bitcasaTree = new dict({'/': '/'})
    @downloadTree = new dict()
    if @accessToken == null
      throw new Error "accessToken in the config file cannot be blank"
    else
      @setRest()

    @downloadLocation = pth.join @cacheLocation, "download"
    @uploadLocation = pth.join @cacheLocation, "upload"
    fs.ensureDirSync(@downloadLocation)
    fs.ensureDirSync(@uploadLocation)

  setRest: ->
    @client = new Client()
    @client.registerMethod 'getRootFolder', "#{BASEURL}folders/?access_token=#{@accessToken}", "GET"
    @client.registerMethod 'downloadChunk', "#{BASEURL}files/name.ext?path=${path}&access_token=#{@accessToken}", "GET"
    @client.registerMethod 'getFolder', "#{BASEURL}folders${path}?access_token=#{@accessToken}&depth=${depth}", "GET"
    @client.registerMethod 'getUserProfile', "#{BASEURL}user/profile?access_token=#{@accessToken}", "GET"
    @client.registerMethod 'deleteFile', "#{BASEURL}files?access_token=#{@accessToken}&path=${path}", "DELETE"
  loginUrl: ->
    "#{BASEURL}oauth2/authenticate?client_id=#{@id}&redirect_url=#{@redirectUrl}"

  authenticate: (code) ->
    url = "#{BASEURL}oauth2/access_token?secret=#{@secret}&code=#{code}"
    new Error("Not implemented")

  validateAccessToken: (cb) ->
    client = @;
    req = @client.methods.getUserProfile  (data, response) ->
      try
        data = JSON.parse(data)
        if data.error
          cb data.error
        else
          cb(null, data)
      catch error
        client.logger.log "debug", "when parsing validation, data was not json"
        cb error


    req.on 'error', (err) ->
      cb err

  ###
  #
  # download file from bitcasa
  # parameters:
  #   client: self, needs to be passed again since we are using fibers
  #   path: the bitcasa path
  #   name: name of the file
  #   start: byte position of where to start downloading
  #   end: byte position of where to end downloading. end is inclusive
  #   maxSize: size of the file
  #   recurse: this should be renamed. recurse is currently used to determine whether the filesystem needs this file, or if it's a read ahead call
  #
  ###
  download: (client, path, name, start,end,maxSize, recurse, cb ) ->
    #round the amount of bytes to be downloaded to multiple chunks
    chunkStart = Math.floor((start)/client.chunkSize) * client.chunkSize
    end = Math.min(end,maxSize)
    chunkEnd = Math.min( Math.ceil(end/client.chunkSize) * client.chunkSize, maxSize)-1 #and make sure that it's not bigger than the actual file

    chunks = (chunkEnd - chunkStart)/client.chunkSize
    if chunks > 1 and (maxSize - start) > 65536
      client.logger.log("debug", "number chunks requested greater than 1 - (start,end) = (#{start}-#{end})")
      client.logger.log("debug", "number chunks requested greater than 1 - (chunkStart,chunkEnd) = (#{chunkStart}-#{chunkEnd})")

    Fiber( ->
      baseName = pth.basename path
      #save location
      location = pth.join(client.downloadLocation,"#{baseName}-#{chunkStart}-#{chunkEnd}")
      client.logger.log('silly',"cache location: #{location}")

      failedArguments =
        buffer: new Buffer(0)
        start: 0
        end: 0

      #check if the data has been cached or not
      #otherwise, download from the web

      if exists(location).wait()
        if recurse
          readSize = end - start;
          buffer = new Buffer(readSize+1)
          fd = open(location,'r').wait()
          bytesRead = read(fd,buffer,0,readSize+1, start-chunkStart).wait()
          close(fd)
          args =
            buffer: buffer
            start: 0
            end: readSize + 1
          client.logger.log('silly',"file exists: #{location}--#{buffer.slice(start,end).length}")
          return cb(null,args)
        else
          cb(null,failedArguments)
      else
        client.logger.log("debug", "#{name} - downloading #{chunkStart}-#{chunkEnd}")
        if client.rateLimit.tryRemoveTokens(1)
          client.logger.log "debug", "download requests: #{client.rateLimit.getTokensRemaining()}"
          args =
            timeout: 360000

            "path":
              "path": path
            headers:
              Range: "bytes=#{chunkStart}-#{chunkEnd}"
          client.logger.log "debug", "starting to download #{location}"
          _download = (_cb) ->
            #ensure callback is only fired once.
            cbCalled = false
            req = client.client.methods.downloadChunk args, (data, response)->
              if not cbCalled
                cbCalled = true
                res = {data:data, response: response, error: null}
                _cb(null, res)

            req.on 'error', (err) ->
              if not cbCalled
                cbCalled = true
                client.logger.log("error","there was an error downloading: #{err}")
                _cb(null, {error: "failed downloading"})

          download = Future.wrap(_download)
          res = download().wait()

          if res.error
            cb(null,failedArguments)
            return

          data = res.data
          response = res.response

          failed = true #assume that the download failed
          apiLimit = false #assume that the error was not hitting the apiLimit
          client.logger.log("debug", "downloaded: #{location} - #{chunkEnd-chunkStart} -- limit #{client.rateLimit.getTokensRemaining()}")

          if not (data instanceof Buffer)
            client.logger.log("debug", "failed to download #{location} -- typeof data: #{typeof data} -- length #{data.length} -- invalid type -- content-type: #{response.headers["content-type"]} -- encoding #{response.headers["content-encoding"]} - path : #{path}")
            client.logger.log("debug", data)
            if response.headers["content-type"] == "application/json; charset=UTF-8"
              res = JSON.parse(data)
              #if file not found,remove it from the tree.
              #this can happen if another client has deleted
              if res.error.code == 2003
                parentPath = client.bitcasaTree.get(pth.dirname(path))
                filePath = pth.join(parentPath,name)
                client.folderTree.delete(filePath)
              if res.error.code == 9006
                apiLimit = true
          else if  data.length < (chunkStart - chunkEnd + 1)
            client.logger.log("debug", "failed to download #{location} -- #{data.length} - size mismatch")
          else
            client.logger.log("debug", "successfully downloaded #{location}")
            writeFile(location,data)
            failed = false


          if failed and apiLimit #api limit
            fiber = Fiber.current
            fiberRun = ->
              fiber.run()
            setTimeout(fiberRun, 61000)
            Fiber.yield()
            cb(null,failedArguments)
          else if recurse and failed  #let the fs decide what to do.
            args =
              buffer: new Buffer(0),
              start: 0,
              end : 0
            cb(null,args)
          else if (failed) and (not recurse)
            client.downloadTree.delete("#{baseName}-#{chunkStart}")
            cb(null, failedArguments)
          else if not failed
            args =
              buffer: data,
              start: start - chunkStart,
              end : end+1-chunkStart
            client.downloadTree.delete("#{baseName}-#{chunkStart}")
            cb(null, args )
        else #for not having enough tokens
          client.logger.log "debug", "downloading file failed: out of tokens"
          cb null, failedArguments


    ).run()

  upload: (client, parentPath, file, cb) ->
    url="#{BASEURL}files#{parentPath}/?access_token=#{client.accessToken}"
    Fiber( ->
      stat = stats(file)
      mime = detectFile(file)

      rest.post url ,
        multipart: true,
        data:
          file:  rest.file( file, null, stat.wait().size, null, mime.wait())
          exists: 'overwrite'

      .on 'complete', (result) ->
        if result instanceof Error
          cb result
        else
          if result.error
            cb result.error
          else
            cb null, result.result.items[0]
    ).run()

  loadFolderTree: (getAll=true)->
    client = @
    jsonFile =  "#{client.cacheLocation}/data/folderTree.json"
    if fs.existsSync(jsonFile)
      fs.readJson jsonFile, (err, data) ->
        for key in Object.keys(data)
          o = data[key]

          #get real path of parent
          parent = client.bitcasaTree.get(pth.dirname(o.path))
          realPath = pth.join(parent,o.name)

          #add child to parent folder
          parentFolder = client.folderTree.get parent

          if o.name not in parentFolder.children
            parentFolder.children.push o.name

          if o.size
            client.folderTree.set key, new BitcasaFile(client, o.path, o.name, o.size, new Date(o.ctime), new Date(o.mtime) )
          else
            # keep track of the conversion of bitcasa path to real path
            client.bitcasaTree.set o.path, realPath
            client.folderTree.set key, new BitcasaFolder(client, o.path, o.name, new Date(o.ctime), new Date( o.mtime), [])
        if getAll
          client.getAllFolders()
    else
      if getAll
        client.getAllFolders()

  saveFolderTree: ->
    client = @
    toSave = {}
    client.folderTree.forEach (value, key) ->
      toSave[key] =
        name: value.name
        mtime: value.mtime.getTime()
        ctime: value.ctime.getTime()
        path: value.bitcasaPath

      if value instanceof BitcasaFile
        toSave[key].size = value.size
    fs.outputJson "#{client.cacheLocation}/data/folderTree.json", toSave, ->
      fn = ->
        client.getAllFolders()
      setTimeout fn, 60000

  #this function will udpate all the folders content
  getAllFolders: ->
    parseLater = [] #sometimes, certain scans will fail, because the parent failed. add these later
    client = @
    newKeys = ['/']
    folders = [client.folderTree.get('/')]
    foldersNextDepth = []
    depth = 1
    oldDepth = 0
    Fiber( ->
      fiber = Fiber.current
      fiberRun = ->
        fiber.run()
      start = new Date()
      while folders.length > 0
        processing = []
        client.logger.log  "silly", "folders length = #{folders.length}, processing length: #{processing.length}"
        tokens = Math.min(Math.floor(client.rateLimit.getTokensRemaining()/6), folders.length - processing.length)
        if client.rateLimit.getTokensRemaining() < 30
          process.nextTick fiberRun
          Fiber.yield()
          continue
        for i in [0...tokens]
          if not client.rateLimit.tryRemoveTokens(1)
            process.nextTick fiberRun
            Fiber.yield()
          processing.push getFolder(client, folders[i].bitcasaPath,depth )
        wait(processing)
        for i in [0...processing.length]
          client.logger.log "silly", "proccessing[#{i}] out of #{processing.length} -- folders length = #{folders.length}"
          processingError = false
          try #catch socket connection error
            data = processing[i].wait()
          catch error
            client.logger.log("error", "there was a problem with connection for folder #{folders[i].name} - #{error}")
            processingError = true

          if processingError
            folders.push(folders[i])
            continue


          try
            result = JSON.parse(data)
          catch error
            client.logger.log "error", "there was a problem processing i=#{i}(#{folders[i].name}) - #{error} - folders length - #{folders.length} - data"
            client.logger.log "debug", "the bad data was: #{data}"
            processingError = true

          if processingError
            folders.push(folders[i])
            continue

          if result.error
            breakLoop = false
            switch result.error.code
              when 2002 #folder does not exist
                parent = client.bitcasaTree.get(pth.dirname(o.path))
                realPath = pth.join(parent,folders[i].name)
                client.folderTree.delete(realPath)
              when 9006
                client.logger.log "debug", "api rate limit reached while getting folders"
                setTimeout fiberRun, 61000
                Fiber.yield()
                for j in [i...processing.length]
                  folders.push(folders[j])
                breakLoop = true
              else
                client.logger.log "error", "there was an error getting folder: #{result.error.code} - #{result.error.message}"

            if breakLoop
              break
            continue

          for o in result.result.items
            #get real path of parent
            parent = client.bitcasaTree.get(pth.dirname(o.path))

            #if the parent does not exist yet, parse later
            if parent == undefined
              parseLater.push o
              continue

            realPath = pth.join(parent,o.name)
            newKeys.push realPath
            #add child to parent folder
            parentFolder = client.folderTree.get parent

            #if parent is undefined, parse later. sometimes, parent errored out while scanning.
            if parentFolder == undefined
              parseLater.push o
              continue

            if o.name not in parentFolder.children
              parentFolder.children.push o.name

            if o.category == 'folders'
              # keep track of the conversion of bitcasa path to real path
              client.bitcasaTree.set o.path, realPath
              existingFolder = client.folderTree.get(realPath)
              children = []
              if existingFolder != undefined
                children = existingFolder.children
              client.folderTree.set( realPath, new BitcasaFolder(client, o.path, o.name, new Date(o.ctime), new Date(o.mtime), children) )
              if o.path.match(/\//g).length  == (oldDepth + depth + 1)
                foldersNextDepth.push client.folderTree.get( realPath)
            else
              client.folderTree.set realPath,    new BitcasaFile(client, o.path, o.name,o.size,  new Date(o.ctime), new Date(o.mtime))

          if result.result.items.length >= 5000
            process.nextTick fiberRun
            Fiber.yield()
        folders.splice 0, processing.length
        console.log "length of folders after splicing: #{folders.length}"
        if folders.length == 0 and foldersNextDepth.length > 0
          keys = BitcasaFolder.parseItems client, parseLater
          newKeys = newKeys.concat keys
          folders = foldersNextDepth
          oldDepth = depth + 1
          depth = foldersNextDepth[0].bitcasaPath.match(/\//g).length
          console.log "length of folders of nextDepth #{folders.length}"
          console.log "new depth is #{depth}"

      client.logger.log "debug", "it took #{Math.ceil( ((new Date())-start)/60000)} minutes to update folders"
      console.log "folderTree Size Before: #{client.folderTree.size}"
      counter = 0
      client.folderTree.forEach (value,key) ->
        Fiber ->
          counter++
          #slow it down so other things can do it's job.
          if counter % 5000 == 0
            fiber = Fiber.current
            fn = ->
              fiber.run()
              setTimeout fn, 1000
            Fiber.yield()
          idx = newKeys.indexOf key
          if idx < 0
            client.folderTree.delete key
            folder = client.folderTree.get pth.dirname(key) #get parent folder
            if folder #it may have already been removed since it's being removed out of order
              idx = (folder.children.indexOf pth.basename(key))
              if idx >= 0
                folder.children.splice idx, 1
          else
            newKeys.splice idx, 1
        .run()
      console.log "folderTree Size After: #{client.folderTree.size}"

      client.saveFolderTree()

    ).run()

  deleteFile: (path,cb) ->

    #@client.registerMethod 'deleteFolders', "#{BASEURL}folders?access_token=#{@accessToken}&path=${path}", "DELETE"
    rest.del "#{BASEURL}files?access_token=#{@accessToken}", {data:{path: path}}
    .on 'complete', (result) ->
      if result instanceof Error
        cb(result)
      else
        if result.error
          cb result.error
        else
          cb null, result
    # args =
    #   path:
    #     path: path
    #
    # req = @client.methods.deleteFile args, (data, response)->
    #   try
    #     data = JSON.parse(data)
    #   catch error
    #     console.log "delete file error", error
    #     console.log data
    #     return cb(new Error "data was likely not json")
    #
    #   res =
    #     data:data
    #     response: response
    #   console.log "log data for delete file" , data
    #   if data.error
    #     cb data.error
    #   else
    #     cb null, res
    # req.on 'error', (err)->
    #   cb err

  createFolder: (path, name, cb) ->
    client = @
    url="#{BASEURL}folders/#{path}/?access_token=#{client.accessToken}"
    Fiber( ->
      rest.post url ,
        data:
          folder_name: name
          exists: 'overwrite'

      .on 'complete', (result) ->
        if result instanceof Error
          cb result
        else
          if result.error
            cb result.error
          else
            cb null, result.result.items[0]
    ).run()

  deleteFolder: (path, cb) ->
    rest.del "#{BASEURL}folders?access_token=#{@accessToken}", {data:{path: path}}
    .on 'complete', (result) ->
      if result instanceof Error
        cb(result)
      else
        if result.error
          cb result.error
        else
          # client.bitcasaTree.set o.path, realPath
          # client.folderTree.set realPath, new BitcasaFolder client, o.path, o.name, o.ctime, o.mtime, []
          cb null, result





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
