module.exports = {
  dependency: {
    platforms: {
      ios: {podspecPath: 'ProxyceptLoggingRN.podspec'},
      android: {sourceDir: './android', packageImportPath: 'import com.proxycept.reactnative.ProxyceptLoggingPackage;',
        packageInstance: 'new ProxyceptLoggingPackage()'},
    },
  },
};
