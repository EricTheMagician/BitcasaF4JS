module.exports = (grunt) ->

  # Project configuration.
  src_files = ['src/*.coffee']
  grunt.initConfig({
    pkg: grunt.file.readJSON('package.json'),
    coffee: {
      compile: {
        files: {
          # 'build/bitcasa/filesystem.js': ['src/file.coffee', 'src/folder.coffee'],
          # 'build/bitcasa/client.js': ['src/client.coffee'],
          'build/fs.js': ['src/file.coffee', 'src/folder.coffee', 'src/client.coffee', 'src/fs.coffee']

        }
      }
    },
    coffee_jshint: {
      options: {
        #Task-specific options go here.
      },
      your_target: {
        src_files
      }
    },

    watch:{
      configFiles: {
        files: [ 'Gruntfile.coffee' ],
        options: {
          reload: true
        }
      },
      scripts:{
        files:['src/*.coffee', 'test/**/*.coffee']
        tasks:['coffee','mochaTest']
      }
    },
    mochaTest: {
      test: {
        options: {
          reporter: 'spec',
          clearRequireCache: true,
          timeout: 30000,
          # require: ['coffee-script/register']
        },
        src: ['test/**/*.coffee']
      }
    }

  });

  grunt.loadNpmTasks('grunt-contrib-coffee');
  grunt.loadNpmTasks('grunt-coffee-jshint');
  grunt.loadNpmTasks('grunt-contrib-watch');
  grunt.loadNpmTasks('grunt-mocha-test');

  # Default task(s).
  grunt.registerTask('default', ['coffee', 'mochaTest']);
