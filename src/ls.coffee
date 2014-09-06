Future = require('fibers/future')
Fiber = require 'fibers'
wait = Future.wait
RedBlackTree = require('data-structures').RedBlackTree
hashmap = require( 'hashmap' ).HashMap
BASEURL = 'https://developer.api.bitcasa.com/v1/'
RateLimiter = require('limiter').RateLimiter
BitcasaFolder = module.exports.folder
BitcasaFile = module.exports.file
config = require('./config.json')
fs = require 'fs-extra'
pth = require 'path'
rest = require 'restler'

ipc = require 'node-ipc'
ipc.config =
  appspace        : 'bitcasaf4js.',
  socketRoot      : '/tmp/',
  id              : "ls",
  networkHost     : 'localhost',
  networkPort     : 8000,
  encoding        : 'utf8',
  silent          : true,
  maxConnections  : 100,
  retry           : 500,
  maxRetries      : 100,
  stopRetrying    : false

winston = require 'winston'
logger = new (winston.Logger)({
    transports: [
      new (winston.transports.Console)({ level: 'info' }),
      new (winston.transports.File)({ filename: '/tmp/BitcasaF4JS.log', level:'debug' })
    ]
  })

_parseFolder = (client,data, cb)->
  fn = ->
    BitcasaFolder.parseFolder(client,data,cb)
  setImmediate fn

parseFolder = Future.wrap(_parseFolder)


keysTree = new RedBlackTree()
client =
  folderTree: new hashmap()
  bitcasaTree: new hashmap()
  rateLimit: new RateLimiter 150, 'minute'
  logger: logger

#wrap get folder
_getFolder = (client, path, depth, cb) ->
  #if not done after 5 minutes, we have a problem
  returned = false
  callback = ->
    unless returned
      returned = true
      cb("taking too long to getFolder")
  timeout = setTimeout callback, 120000

  rest.get "#{BASEURL}folders#{path}?access_token=#{config.accessToken}&depth=#{depth}", {
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

loadFolderTree = ->
  jsonFile =  "#{config.cacheLocation}/data/folderTree.json"
  now = Date.now()
  client.folderTree.set '/', new BitcasaFolder(client, '/', 'root', now, now, [], true)
  client.bitcasaTree.set( '/', '/')

  if fs.existsSync(jsonFile)
    fs.readJson jsonFile, (err, data) ->
      for key in Object.keys(data)
        o = data[key]

        #make sure parent directory exists
        unless client.bitcasaTree.has(pth.dirname(o.path))
          continue

        keysTree.add key
        #get real path of parent
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

      getAllFolders()
  else
    console.log 'did not exist'
    getAllFolders()




saveFolderTree =  ->
  toSave = {}
  for key in client.folderTree.keys()
    value = client.folderTree.get key
    toSave[key] =
      name: value.name
      mtime: value.mtime
      ctime: value.ctime
      path: value.bitcasaPath

    if value instanceof BitcasaFile
      toSave[key].size = value.size
  fs.outputJson "#{config.cacheLocation}/data/folderTree.json", toSave, ->
    fn = ->
      getAllFolders()
    setTimeout fn, 60000

#this function will udpate all the folders content

getAllFolders= ->
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
      logger.log  "silly", "folders length = #{folders.length}"
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
        logger.log "silly", "proccessing[#{i}] out of #{processing.length} -- folders length = #{folders.length}"
        processingError = false
        try #catch socket connection error
          data = processing[i].wait()
        catch error
          logger.log("error", "there was a problem with getting data for folder #{folders[i].name} - #{error}")
          folders.push(folders[i])
          processingError = true

        if processingError
          setImmediate fiberRun
          Fiber.yield()
          continue


        try
          keys = parseFolder(client,data).wait()
        catch error
          logger.log "error", "there was a problem processing i=#{i}(#{folders[i].name}) - #{error} - folders length - #{folders.length} - data"
          logger.log "debug", "the bad data was:", data
          processingError = true

          switch error.code
            when 9006
              apiRateLimit = true
              folders.push(folders[i])
            when 2001
              client.folderTree.remove client.convertRealPath(folders[i])
            when 2002
              client.folderTree.remove client.convertRealPath(folders[i])
            else
              folders.push( folders[i])

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
      if apiRateLimit
        setTimeout fiberRun, 61000
        Fiber.yield()

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


    logger.log "debug", "it took #{Math.ceil( ((new Date())-start)/60000)} minutes to update folders"
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
      unless keysTree.has(key)
        keysTree.add key
        obj = client.folderTree.get key
        ipc.of.client.emit 'ls:add',
          realPath: key
          path: obj.path
          name: obj.name
          mtime: obj.mtime
          ctime: obj.ctime
          size: obj.size

      unless client.folderTree.get(key).updated
        client.folderTree.remove(key)
        keysTree.remove key
        ipc.of.client.emit 'ls:delete', key

    console.log "folderTree Size After: #{client.folderTree.count()}"

    saveFolderTree()

  ).run()
  return null

fn = ->
  ipc.connectTo 'client', ->
    ipc.of.client.on 'connect', ->
      loadFolderTree()

setTimeout fn, 120000
