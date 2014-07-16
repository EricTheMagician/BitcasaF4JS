class BitcasaFile
  @fileAttr: 0o100777 #according to filesystem information, the 15th bit is set and the read and write are available for everyone
  constructor: (@client,@bitcasaPath, @name, @size, @ctime, @mtime) ->

  download: (start,end, cb) ->
    @client.download(@bitcasaPath, @name, start,end,@size,true,cb)

  getAttr: (cb)->
    attr =
      mode: BitcasaFile.fileAttr,
      size: @size,
      nlink: 1,
      mtime: @mtime,
      ctime: @ctime
    console.log "#{@name} #{attr}"
    cb(0,attr)


module.exports.file = BitcasaFile
