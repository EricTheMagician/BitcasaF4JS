pth = require 'path'

#for mocha testing
if Object.keys( module.exports ).length == 0
  r = require './file.coffee'
  BitcasaFile = r.file
else
  BitcasaFile = module.exports.file

class BitcasaFolder
  @folderAttr = 0o40777 ##according to filesystem information, the 14th bit is set and the read and write are available for everyone

  constructor: (@client, @bitcasaPath, @name, @ctime, @mtime, @children = [])->

  @parseItems: (client,items) ->
    for o in items
      parent = client.bitcasaTree.get(pth.dirname(o.path))
      realPath = pth.join(parent,o.name)

      #add child to parent folder
      parentFolder = client.folderTree.get parent
      if o.name not in parentFolder.children
        parentFolder.children.push o.name

      if o.category == 'folders'
        # keep track of the conversion of bitcasa path to real path
        client.bitcasaTree.set o.path, realPath
        client.folderTree.set( realPath, new BitcasaFolder(client, o.path, o.name, new Date(o.ctime), new Date(o.mtime), []) )
      else
        client.folderTree.set realPath, new BitcasaFile(client, o.path, o.name,o.size,  new Date(o.ctime), new Date(o.mtime))


  @parseFolder: (data, response, client, retry, cb) ->
    try
      data = JSON.parse(data)
      # console.log(data.result)
      if data.error
        throw new Error('error with parsing folder')
      for o in data.result.items
        # console.log o
        #get real path of parent
        parent = client.bitcasaTree.get(pth.dirname(o.path))
        realPath = pth.join(parent,o.name)

        #add child to parent folder
        parentFolder = client.folderTree.get parent
        if o.name not in parentFolder.children
          parentFolder.children.push o.name

        if o.category == 'folders'
          # keep track of the conversion of bitcasa path to real path
          client.bitcasaTree.set o.path, realPath
          client.folderTree.set( realPath, new BitcasaFolder(client, o.path, o.name, new Date(o.ctime), new Date(o.mtime), []) )
        else
          client.folderTree.set realPath, new BitcasaFile(client, o.path, o.name,o.size,  new Date(o.ctime), new Date(o.mtime))
    catch error
      client.logger.log "debug", 'data was likely not a json variable', error, data
      if typeof(retry) == typeof(Function)
        retry()
    if typeof(cb) == typeof(Function)
      cb()
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
      client.bitcasaTree.delete folder.bitcasaPath
      client.folderTree.delete realPath

      parentFolder = client.folderTree.get pth.dirname realPath
      idx = parentFolder.children.indexOf folder.name
      parentFolder.children.splice idx, 1

      cb null, true
    if @children.length == 0
      client.deleteFolder(@bitcasaPath, callback)
    else
      cb("folder not empty")



module.exports.folder = BitcasaFolder
