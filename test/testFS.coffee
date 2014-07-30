chai = require "chai"
winston = require 'winston'
expect = chai.expect
md5 = require 'MD5'
config = require '../build/config.json'
fs = require 'fs'
sys = require('sys')
exec = require('child_process').exec;

describe.skip 'FUSE filesystem', ->

  it 'should be mountable', (done)->
    require '../src/fs.coffee'
    done()

  it 'should list the infinite drive', (done) ->
    callback = (err,stdout, stderr)->
      if err
        done("There was an error #{err}")
      expect(stdout).to.contain("Bitcasa Infinite Drive")
      done()
    fn = ->
      exec("ls #{config.mountPoint}", callback )
    setTimeout(fn, 15000)



  it 'should be unmountable', (done) ->
    callback = (err,stdout, stderr)->
      if err
        done("There was an error #{err}")
      expect(stdout).to.equal("Unmount successful for #{config.mountPoint}\n")
      done()
    fn = ->
      exec("diskutil unmount force #{config.mountPoint}", callback )

    setTimeout(fn, 2000)
