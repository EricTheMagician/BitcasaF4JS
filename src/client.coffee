BASEURL = 'https://developer.api.bitcasa.com/v1/'
RateLimiter = require('limiter').RateLimiter
Client = require('node-rest-client').Client;
hashmap = require( 'hashmap' ).HashMap
pth = require 'path'
fs = require 'fs-extra'
memoize = require 'memoizee'
Future = require('fibers/future')
Fiber = require 'fibers'
wait = Future.wait
RedBlackTree = require('data-structures').RedBlackTree
EventEmitter = require("events").EventEmitter

ipc = require 'node-ipc'
failedArgs =
  buffer: new Buffer(0)
  start:0
  end:0
ipc.config =
  appspace        : 'bitcasaf4js.',
  socketRoot      : '/tmp/',
  id              : "client",
  networkHost     : 'localhost',
  networkPort     : 8000,
  encoding        : 'utf8',
  silent          : true,
  maxConnections  : 100,
  retry           : 500,
  maxRetries      : 100,
  stopRetrying    : false


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
    @downloadServer = 0
    for i in [0...6]
      ipc.connectTo "download#{i}"


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
  download: (client, file, path, name, start,end,maxSize, recurse, cb ) ->
    chunkStart = Math.floor((start)/client.chunkSize) * client.chunkSize
    chunkEnd = Math.min( Math.ceil(end/client.chunkSize) * client.chunkSize, maxSize)-1 #and make sure that it's not bigger than the actual file
    basename = file.bitcasaBasename

    location = pth.join(client.downloadLocation,"#{basename}-#{chunkStart}-#{chunkEnd}")

    readFile = ->
      if recurse
        Fiber ->
          readSize = end - start;
          buffer = new Buffer(readSize+1)

          try #sometimes, the cached file might deleted. if that happens, just try downloading/reading it again later
            fd = open(location,'r').wait()
          catch error
            client.logger.log "error", "there was a problem opening file: #{basename}-#{chunkStart}-#{chunkEnd}"
            fn = ->
              client.download(client, file, path, name, start,end,maxSize, recurse, cb )
            setImmediate fn
            return
          bytesRead = read(fd,buffer,0,readSize+1, start-chunkStart).wait()
          close(fd)
          args =
            buffer: buffer
            start: 0
            end: readSize + 1
          client.ee.emit 'downloaded', null, "#{file.bitcasaBasename}-#{start}", args
          cb(null, args)
          return null
        .run()
      else
        client.ee.emit 'downloaded', null, "#{file.bitcasaBasename}-#{start}", failedArgs
        cb(null, failedArgs)

      return null

    if fs.existsSync(location)
      readFile()
    else
      inData =
        path: path
        name: name
        start: start
        end: end
        maxSize: maxSize
      downloadServer = "download#{client.downloadServer}"
      client.downloadServer = (client.downloadServer + 1)% 2

      ipc.of[downloadServer].emit 'download', inData
      ipc.of[downloadServer].on 'downloaded', (data) ->
        if path == data.path and start == data.ostart
          readFile()
        return null



    return null


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
        apiRateLimit = false
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
            client.logger.log "debug", "the bad data was:", data
            processingError = true
            if error.message == 9006
              apiRateLimit == true

            folders.push(folders[i])

            processingError = true

          if apiRateLimit
            setTimeout fiberRun, 61000
            Fiber.yield()
            folders.splice(0, i)
            break


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
