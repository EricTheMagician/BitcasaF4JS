#BitcasaF4JS

##Information
This is a simple (incomplete) filesystem written in NodeJS to mount Bitcasa as a local drive.

##Installing

###Requirements
Linux / MacOSX with FUSE.

**Fuse is not compatible with Windows.**

NodeJS:

1. npm install -g grunt-cli
2. git clone https://github.com/thejinx0r/BitcasaF4JS.git
3. cd BitcasaF4JS
4. npm install
5. grunt coffee
6. cd build
7. copy the config.json.sample to config.json and edit it.
8. node fs.js
9. optional: node watch.js


##Todo
1. Implement file uploads: this will be implemented after the new upload server is functioning with pause/resume uploading
