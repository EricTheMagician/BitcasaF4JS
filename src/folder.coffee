pth = require 'path'

#for mocha testing
if Object.keys( module.exports ).length == 0
  r = require './file.coffee'
  BitcasaFile = r.file
else
  BitcasaFile = module.exports.file

class BitcasaFolder
  @folderAttr = 16895 ##according to filesystem information, the 14th bit is set and the read and write are available for everyone

  constructor: (@client, @bitcasaPath, @name, @ctime, @mtime, @children = [])->

  @parseFolder: (data, response, client, cb) ->
    # console.log(response)
    data = JSON.parse(data)
    # console.log(data.result)
    if data.error
    	new Error('error with parsing folder')
    for o in data.result.items
    	# console.log o

    	#get real path of parent
    	parent = client.bitcasaTree.get(pth.dirname(o.path))
    	realPath = pth.join(parent,o.name)

    	#add child to parent folder
    	parentFolder = client.folderTree.get parent
    	parentFolder.children.push o.name

    	if o.category == 'folders'
    		# keep track of the conversion of bitcasa path to real path
        client.bitcasaTree.set o.path, realPath
        client.folderTree.set realPath, new BitcasaFolder(client, o.path, o.name, o.ctime, o.mtime)
	    else
        client.folderTree.set realPath, new BitcasaFile(client, o.path, o.name, o.ctime, o.mtime)

    if typeof(cb) == typeof(Function)
      cb()
  getAttr: (cb)->
    attr =
      mode: BitcasaFolder.folderAttr,
      nlink: @children.length + 1,
      mtime: @mtime,
      ctime: @ctime
    cb(0,attr)

module.exports.folder = BitcasaFolder
