class BitcasaFile
  constructor: (@client, @name, @size, @dateModified, @dateCreated, @bitcasaPath, @path) ->

module.exports.file = BitcasaFile
