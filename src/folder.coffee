class BitcasaFolder
  constructor: ->

  @parseFolder: (data, response, client, cb) ->
    # console.log(response)
    if typeof(cb) == typeof(Function)
      cb()

module.exports.folder = BitcasaFolder
