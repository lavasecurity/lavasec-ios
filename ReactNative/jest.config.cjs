module.exports = {
  preset: '@react-native/jest-preset',
  moduleNameMapper: {'^.*specs/LavaContextMenuNativeComponent$':'<rootDir>/tests/native-context-menu-mock.tsx','^.*specs/LavaSwitchNativeComponent$':'<rootDir>/tests/native-switch-mock.tsx','^@react-navigation/elements$':'<rootDir>/tests/native-header-height-mock.ts'},
  testMatch: ['<rootDir>/tests/**/*.test.[jt]s?(x)'],
  // i18n coverage: see tests/i18n-coverage/global-teardown.js.
  globalSetup: '<rootDir>/tests/i18n-coverage/global-setup.js',
  globalTeardown: '<rootDir>/tests/i18n-coverage/global-teardown.js',
  setupFilesAfterEnv: ['<rootDir>/tests/i18n-coverage/observe.ts'],
  moduleFileExtensions: ['ios.tsx', 'ios.ts', 'ts', 'tsx', 'js', 'jsx', 'json', 'node'],
};
