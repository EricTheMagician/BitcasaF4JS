class BitcasaFile
  @fileAttr: 33279 #according to filesystem information, the 15th bit is set and the read and write are available for everyone
  constructor: (@client,@bitcasaPath, @name, @size, @ctime, @mtime) ->

  download: (start=0,end=-1) ->
    @client.download(@bitcasaPath, @name, start,end,@size)

  getattr: (cb)->
    attr =
      mode: BitcasaFile.fileAttr,
      size: @size,
      nlink: 1,
      mtime: @mtime,
      ctime: @ctime
    cb(0,attr)


module.exports.file = BitcasaFile
