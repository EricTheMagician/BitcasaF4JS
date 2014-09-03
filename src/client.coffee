BASEURL = 'https://developer.api.bitcasa.com/v1/'
RateLimiter = require('limiter').RateLimiter
Client = require('node-rest-client').Client;
hashmap = require( 'hashmap' ).HashMap
pth = require 'path'
fs = require 'fs-extra'
memoize = require 'memoizee'
d = require('d');
Future = require('fibers/future')
Fiber = require 'fibers'
wait = Future.wait
RedBlackTree = require('data-structures').RedBlackTree
util         = require("util")
EventEmitter = require("events").EventEmitter

_parseFolder = (client,data, cb)->
  fn = ->
    BitcasaFolder.parseFolder(client,data,cb)
  setImmediate fn

parseFolder = Future.wrap(_parseFolder)

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
  #if not done after 5 minutes, we have a problem
  returned = false
  callback = ->
    unless returned
      returned = true
      cb("taking too long to getFolder")
  timeout = setTimeout callback, 120000

  rest.get "#{BASEURL}folders#{path}?access_token=#{client.accessToken}&depth=#{depth}", {
    timeout: 90000
  }
  .on 'complete', (result, response) ->
    unless returned
      returned = true
      clearTimeout timeout
      if result instanceof Error
        cb(result)
      else
        cb(null, result)




getFolder = Future.wrap(_getFolder)


memoizeMethods = require('memoizee/methods')
existsMemoized = memoize(fs.existsSync, {maxAge:5000})
class BitcasaClient
  constructor: (@id, @secret, @redirectUrl, @logger, @accessToken = null, @chunkSize = 1024*1024, @advancedChunks = 10, @cacheLocation = '/tmp/node-bitcasa') ->
    @rateLimit = new RateLimiter 175, 'minute'
    now = (new Date).getTime()
    root = new BitcasaFolder(@,'/', '', now, now, [], true)
    @folderTree = new hashmap()
    @folderTree.set("/", root)
    @bitcasaTree = new hashmap()
    @bitcasaTree.set("/", "/")
    @downloadTree = new hashmap()
    @setRest()
    @ee = new EventEmitter()
    @ee.setMaxListeners(0)
    @downloadLocation = pth.join @cacheLocation, "download"
    @uploadLocation = pth.join @cacheLocation, "upload"
    fs.ensureDirSync(@downloadLocation)
    fs.ensureDirSync(@uploadLocation)

  setRest: ->
    @client = new Client()
    @client.registerMethod 'getFolder', "#{BASEURL}folders${path}?access_token=#{@accessToken}&depth=${depth}", "GET"
    @client.registerMethod 'getUserProfile', "#{BASEURL}user/profile?access_token=#{@accessToken}", "GET"

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

  convertRealPath: (obj) ->
    parent = pth.dirname obj.bitcasaPath
    return pth.join( client.bitcasaTree.get(parent), obj.name  )

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
          client.ee.emit "downloaded", null, "#{baseName}-#{chunkStart}", args
          return cb(null,args)
        else
          client.ee.emit "downloaded", null, "#{baseName}-#{chunkStart}", failedArguments
          return cb(null,failedArguments)
      else
        client.logger.log("debug", "downloading #{name} - #{chunkStart}-#{chunkEnd}")
        if client.rateLimit.tryRemoveTokens(1)
          client.logger.log "silly", "download requests: #{client.rateLimit.getTokensRemaining()}"
          client.logger.log "silly", "starting to download #{location}"

          _download = (_cb) ->
            called = false
            rest.get "#{BASEURL}files/name.ext?path=#{path}&access_token=#{client.accessToken}", {
              decoding: "buffer"
              timeout: 300000
              headers:
                Range: "bytes=#{chunkStart}-#{chunkEnd}"
            }
            .on 'complete', (result, response) ->
              if result instanceof Error
                _cb(null, {error: result})
              else
                if result instanceof Error
                  _cb(null, {error: result})
                else
                  if response.headers["content-type"].length == 0 #if it's raw data
                    _cb(null, {error:null, data: response.raw, response: response})
                  else
                    try #check to see if it's json
                      data = JSON.parse(result)
                      _cb(null, {error:null, data: data, response: response})
                    catch #it might return html for some reason
                      _cb(null, {error:null, data: response.raw, response: response})

          download = Future.wrap(_download)
          res = download().wait()

          if res.error
            client.ee.emit res.error.message, "#{baseName}-#{chunkStart}",failedArguments
            cb(res.error.message)
            return

          data = res.data
          response = res.response

          client.logger.log("debug", "downloaded: #{location} - #{chunkEnd-chunkStart} -- limit #{client.rateLimit.getTokensRemaining()}")

          if not (data instanceof Buffer)
            client.logger.log("debug", "failed to download #{location} -- typeof data: #{typeof data} -- length #{data.length} -- invalid type -- content-type: #{response.headers["content-type"]} -- encoding #{response.headers["content-encoding"]} - path : #{path}")
            client.logger.log("debug", data)
            if response.headers["content-type"] == "application/json; charset=UTF-8"
              res = JSON.parse(data)
              code = res.error.code;
              #if file not found,remove it from the tree.
              #this can happen if another client has deleted
              if code == 2003 or code == 3001
                parentPath = client.bitcasaTree.get(pth.dirname(path))
                filePath = pth.join(parentPath,name)
                client.folderTree.remove(filePath)
                client.ee.emit "downloaded", "file does not exist anymore","#{baseName}-#{chunkStart}", failedArguments
                return cb("file does not exist anymore")
              if code == 9006
                client.ee.emit "downloaded", "api rate limit reached while downloading","#{baseName}-#{chunkStart}", failedArguments
                return cb "api rate limit reached while downloading"

              client.ee.emit "downloaded", "unhandled json error", "#{baseName}-#{chunkStart}", failedArguments
              return cb "unhandled json error"

            client.ee.emit "downloaded", "unhandled data type", "#{baseName}-#{chunkStart}", failedArguments
            return cb "unhandled data type while downloading"
          else if  data.length !=  (chunkEnd - chunkStart + 1)
            client.logger.log("debug", "failed to download #{location} -- #{data.length} -- #{chunkStart - chunkEnd + 1} -- size mismatch")
            client.ee.emit "downloaded", "data downloaded incorrectSize", "#{baseName}-#{chunkStart}", failedArguments
            return cb "data downloaded incorrectSize"
          else
            client.logger.log("debug", "successfully downloaded #{location}")
            args =
              buffer: data,
              start: start - chunkStart,
              end : end+1-chunkStart

            client.ee.emit "downloaded", null,"#{baseName}-#{chunkStart}", args
            cb null, args
            return writeFile(location,data).wait()

        else #for not having enough tokens
          client.logger.log "debug", "downloading file failed: out of tokens"
          client.ee.emit "downloaded", "downloading file failed: out of tokens", "#{baseName}-#{chunkStart}", args
          return cb null, failedArguments


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
          unless client.bitcasaTree.has(pth.dirname(o.path))
            continue

          parent = client.bitcasaTree.get(pth.dirname(o.path))
          realPath = pth.join(parent,o.name)

          #add child to parent folder
          parentFolder = client.folderTree.get parent

          if o.name not in parentFolder.children
            parentFolder.children.push o.name

          if o.size
            client.folderTree.set key, new BitcasaFile(client, o.path, o.name, o.size, o.ctime, o.mtime, true )
          else
            # keep track of the conversion of bitcasa path to real path
            client.bitcasaTree.set o.path, realPath
            client.folderTree.set key, new BitcasaFolder(client, o.path, o.name, o.ctime, o.mtime, [], true)
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
        mtime: value.mtime
        ctime: value.ctime
        path: value.bitcasaPath

      if value instanceof BitcasaFile
        toSave[key].size = value.size
    fs.outputJson "#{client.cacheLocation}/data/folderTree.json", toSave, ->
      fn = ->
        client.getAllFolders()
      setTimeout fn, 60000

  #this function will udpate all the folders content

  getAllFolders: ->
    client = @
    folders = [client.folderTree.get('/')]
    foldersNextDepth = []
    depth = 1
    oldDepth = 0
    Fiber( ->
      fiber = Fiber.current
      fiberRun = ->
        fiber.run()
        return null
      start = new Date()
      value.updated = false for value in client.folderTree.values()
      client.folderTree.get('/').updated = true

      #pause for a little after getting all keys
      setImmediate fiberRun
      Fiber.yield()

      while folders.length > 0
        client.logger.log  "silly", "folders length = #{folders.length}"
        tokens = Math.min(Math.floor(client.rateLimit.getTokensRemaining()/6), folders.length)
        if client.rateLimit.getTokensRemaining() < 30
          setImmediate fiberRun
          Fiber.yield()
          continue

        processing = new Array(tokens)
        for i in [0...tokens]
          if not client.rateLimit.tryRemoveTokens(1)
            setTimeout fiberRun, 1000
            Fiber.yield()
          processing[i] = getFolder(client, folders[i].bitcasaPath,depth )
        wait(processing)
        for i in [0...processing.length]
          client.logger.log "silly", "proccessing[#{i}] out of #{processing.length} -- folders length = #{folders.length}"
          processingError = false
          try #catch socket connection error
            data = processing[i].wait()
          catch error
            client.logger.log("error", "there was a problem with getting data for folder #{folders[i].name} - #{error}")
            folders.push(folders[i])
            processingError = true

          if processingError
            setImmediate fiberRun
            Fiber.yield()
            continue


          try
            keys = parseFolder(client,data).wait()
          catch error
            client.logger.log "error", "there was a problem processing i=#{i}(#{folders[i].name}) - #{error} - folders length - #{folders.length} - data"
            client.logger.log "debug", "the bad data was: #{data}"
            processingError = true

            switch error.code
              when 9006
                setTimeout fiberRun, 61000
                Fiber.yield()
                folders.push(folders[i])
                folders.splice(0, i)
              when 2001
                client.folderTree.remove client.convertRealPath(folders[i])
              when 2002
                client.folderTree.remove client.convertRealPath(folders[i])

          if processingError
            setImmediate fiberRun
            Fiber.yield()
            continue

          for key in keys
            if key.match(/\//g).length  == (oldDepth + depth + 1)
              o = client.folderTree.get key
              if o instanceof BitcasaFolder
                foldersNextDepth.push o

          setImmediate fiberRun
          Fiber.yield()


        folders.splice 0, processing.length
        console.log "length of folders after splicing: #{folders.length}"
        if folders.length == 0 and foldersNextDepth.length > 0
          folders = foldersNextDepth
          foldersNextDepth = []
          oldDepth = depth + 1
          depth = folders[0].bitcasaPath.match(/\//g).length
          console.log "length of folders of nextDepth #{folders.length}"
          console.log "new depth is #{depth}"
          setImmediate fiberRun
          Fiber.yield()


      client.logger.log "debug", "it took #{Math.ceil( ((new Date())-start)/60000)} minutes to update folders"
      console.log "folderTree Size Before: #{client.folderTree.count()}"

      #pause for a little after getting all keys
      setImmediate fiberRun
      Fiber.yield()
      counter = 0
      for key in client.folderTree.keys()
        counter++
        if counter % 1000 == 0
          setImmediate fiberRun
          Fiber.yield()

        unless client.folderTree.get(key).updated
          client.folderTree.remove(key)

      console.log "folderTree Size After: #{client.folderTree.count()}"

      client.saveFolderTree()

    ).run()
    return null

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

module.exports.client = BitcasaClient
