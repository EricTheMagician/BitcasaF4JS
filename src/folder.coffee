pth = require 'path'
Fiber = require 'fibers'
#for mocha testing
if Object.keys( module.exports ).length == 0
  r = require './file.coffee'
  BitcasaFile = r.file
else
  BitcasaFile = module.exports.file

class BitcasaFolder
  @folderAttr = 0o40777 ##according to filesystem information, the 14th bit is set and the read and write are available for everyone

  constructor: (@client, @bitcasaPath, @name, @ctime, @mtime, @children, @updated)->

  @parseFolder: (client, result, cb) ->

    if result.error
      breakLoop = false
      switch result.error.code
        when 2001
          client.logger.log "debug", "manifest does not exist"
        when 2002 #folder does not exist
          client.logger.log "debug", "folder does not exist anymore"
        when 9006
          client.logger.log "debug", "api rate limit reached while getting folders"
        else
          client.logger.log "error", "there was an error getting folder: #{result.error.code} - #{result.error.message}"
      cb(result.error)
      return null

    keys = []
    count = 0
    Fiber ->
      fiber = Fiber.current
      fiberRun = ->
        fiber.run()
      for o in result.result.items
        count++
        if count % 50 == 0
          setImmediate fiberRun
          Fiber.yield()
        #get real path of parent
        parent = client.bitcasaTree.get(pth.dirname(o.path))

        #if the parent does not exist, skip it
        if parent == undefined
          continue

        realPath = pth.join(parent,o.name)

        parentFolder = client.folderTree.get parent
        #if parent is undefined, parse later. sometimes, parent errored out while scanning.
        if parentFolder == undefined
          continue

        #add child to parent
        if o.name not in parentFolder.children
          parentFolder.children.push o.name

        if o.category == 'folders'
          # keep track of the conversion of bitcasa path to real path
          client.bitcasaTree.set o.path, realPath
          keys.push realPath

          if ( obj = client.folderTree.get( realPath ) ) and obj instanceof BitcasaFolder
            if obj.mtime.getTime() !=  o.mtime
              obj.mtime = new Date(o.mtime)
            obj.updated = true
          else
            client.folderTree.set( realPath, new BitcasaFolder(client, o.path, o.name, new Date(o.ctime), new Date(o.mtime), [], true) )
        else
          if obj = client.folderTree.get( realPath ) and obj instanceof BitcasaFile
            if obj.mtime.getTime() !=  o.mtime
              obj.mtime = new Date(o.mtime)
            obj.updated = true
          else
            client.folderTree.set realPath,    new BitcasaFile(client, o.path, o.name,o.size,  new Date(o.ctime), new Date(o.mtime), true)
      _cb = ->
        cb(null, keys)
      setImmediate _cb

    .run()

    return null
  getAttr: (cb)->
    attr =
      mode: BitcasaFolder.folderAttr,
      size: 4096 #standard size of a directory
      nlink: @children.length + 1,
      mtime: @mtime,
      ctime: @ctime
    cb(0,attr)

  uploadFile: (filePath, cb) ->
    folder = @
    client = @client
    filename = pth.basename filePath
    parentPath = client.bitcasaTree.get @bitcasaPath

    newPath = pth.join parentPath, filename

    callback = (err, arg)->
      if err
        return cb err
      client.folderTree.set newPath, new BitcasaFile(client, arg.path, arg.name, arg.size, new Date(arg.ctime), new Date(arg.mtime) )
      if filename not in folder.children
        folder.children.push filename
      cb null, arg
    @client.upload client, @bitcasaPath, filename, callback

  createFolder: (name, cb) ->
    client = @client
    folder = @
    newPath = "#{client.bitcasaTree.get(folder.bitcasaPath)}/#{name}"
    callback = (err, args) ->
      if err
        cb err
      else
        client.folderTree.set newPath, new BitcasaFolder(client, args.path, args.name, new Date( args.ctime), new Date( args.mtime) , [])
        client.bitcasaTree.set args.path, newPath
        folder.children.push name
        cb null, args
    if client.folderTree.has newPath
      cb("folder already exists")
    else
      client.createFolder(@bitcasaPath,name, callback)

  delete: (cb) ->
    folder = @
    client = @client
    callback = (err, args) ->
      if err
        return cb err
      realPath = client.bitcasaTree.get folder.bitcasaPath
      client.bitcasaTree.remove folder.bitcasaPath
      client.folderTree.remove realPath

      parentFolder = client.folderTree.get pth.dirname realPath
      idx = parentFolder.children.indexOf folder.name
      parentFolder.children.splice idx, 1

      cb null, true
    if @children.length == 0
      client.deleteFolder(@bitcasaPath, callback)
    else
      cb("folder not empty")



module.exports.folder = BitcasaFolder
