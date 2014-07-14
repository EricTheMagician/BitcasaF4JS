class BitcasaFile
  constructor: (@client, @name, @size, @ctime, @mtime, @bitcasaPath) ->

  download: (start=0,end=-1) ->
  	

module.exports.file = BitcasaFile
