chai = require "chai"
winston = require 'winston'
expect = chai.expect
md5 = require 'MD5'
config = require '../build/test.config.json'
fs = require 'fs-extra'
sys = require 'sys'
exec = require('child_process').exec;

describe.only 'FUSE filesystem', ->

  it 'should be mountable', (done)->
    require '../src/fs.coffee'
    setTimeout done, 5000

  it 'should list the infinite drive', (done) ->
    callback = (err,stdout, stderr)->
      if err
        done("There was an error #{err}")
      expect(stdout).to.contain("Bitcasa Infinite Drive")
      done()
    exec("ls #{config.mountPoint}", callback )

  it 'should be able to create a directory'
  it 'should not be able to create a directory with more than 64 chars'
  it 'should be able to create a file'
  it 'should not be able to remove a non-empty folder'
  it 'should be able to delete a file'
  it 'should be able to move directories'
  it 'should be able to move files'
  it 'should be able to copy files'
  it 'should be able to delete an empty folder'


  it 'should be unmountable', (done) ->
    callback = (err,stdout, stderr)->
      if err
        console.log err
        done("There was an error #{err}")
      expect(stdout).to.equal("Unmount successful for #{config.mountPoint}\n")
      done()
    fn = ->
      exec("diskutil unmount force #{config.mountPoint}", callback )

    setTimeout(fn, 2000)
