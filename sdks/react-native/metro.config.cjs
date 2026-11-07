const {getDefaultConfig} = require('@react-native/metro-config');
const config = getDefaultConfig(__dirname);
config.maxWorkers = 2;
module.exports = config;
