module.exports = (grunt) ->

  # Project configuration.
  src_files = ['src/*.coffee']
  grunt.initConfig({
    pkg: grunt.file.readJSON('package.json'),
    coffee: {
      compile: {
        files: {
          'build/BitcasaFS.js': ['src/*.coffee'],

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
      scripts:{
        files:['src/*.coffee']
        tasks:['coffee']
      }
    }
  });

  grunt.loadNpmTasks('grunt-contrib-coffee');
  grunt.loadNpmTasks('grunt-coffee-jshint');
  grunt.loadNpmTasks('grunt-contrib-watch');

  # Default task(s).
  grunt.registerTask('default', ['coffee', 'coffee_jshint']);
