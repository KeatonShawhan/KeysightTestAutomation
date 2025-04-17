const { defineConfig } = require('cypress');
const fs = require('fs');
const path = require('path');

module.exports = defineConfig({
  chromeWebSecurity: false,
  defaultCommandTimeout: 30000,
  requestTimeout: 30000,
  responseTimeout: 30000,
  viewportHeight: 1080,
  viewportWidth: 1920,
  watchForFileChanges: false,
  e2e: {
    baseUrl: 'https://test-automation.pw.keysight.com',
    specPattern: 'cypress/tests/**/*.spec.js',
    supportFile: 'cypress/support/e2e.js',
    experimentalOriginDependencies: true, // Moved inside e2e object
    setupNodeEvents(on, config) {
      // Load environment-specific credentials
      const environment = config.env.environment || 'sample';
      const credentialsFile = path.resolve(__dirname, `cypress/credentials/${environment}.json`);

      console.log(`Loading credentials for environment: ${environment}`);
      console.log(`Looking for credentials file: ${credentialsFile}`);

      if (fs.existsSync(credentialsFile)) {
        console.log(`Credentials file found for ${environment}`);
        const credentials = JSON.parse(fs.readFileSync(credentialsFile, 'utf-8'));
        
        // Merge credentials into config.env
        config.env = {
          ...credentials,
          ...config.env,
          credentialsLoaded: true,
          currentEnvironment: environment
        };
        
        console.log('Loaded credentials:');
        console.log(`- USERNAME: ${credentials.USERNAME ? 'Set' : 'Not set'}`);
        console.log(`- client-ID: ${credentials['client-ID'] || 'Not set'}`);
        console.log(`- realm: ${credentials.realm || 'Not set'}`);
      } else {
        console.warn(`Credentials file not found for environment: ${environment}`);
        
        // Set fallback values for testing without real credentials
        config.env = {
          ...config.env,
          USERNAME: 'test-user@gmail.com',
          PASSWORD: 'testpass123',
          'client-ID': 'clt-test-automation-ui',
          realm: 'csspp2025',
          authUrl: 'https://keycloak.pw.keysight.com',
          baseRealmSwitchUrl: 'https://pathwave-home.pw.keysight.com/?realm=',
          mainRunner: 'CampaignRunner',
          redirectUrl: 'https://test-automation.pw.keysight.com',
          tag: 'AWS Production',
          userIdUrl: 'https://keycloak-broker-service.pw.keysight.com/',
          userToken: 'false',
          credentialsLoaded: false,
          currentEnvironment: 'fallback'
        };
        
        console.log('Using fallback credentials for testing');
      }

      // Add task for writing files (to save auth token if needed)
      on('task', {
        writeFile({ path, contents }) {
          // Make sure directory exists
          const dirPath = path.substring(0, path.lastIndexOf('/'));
          if (!fs.existsSync(dirPath)) {
            fs.mkdirSync(dirPath, { recursive: true });
          }
          
          // Write the file
          fs.writeFileSync(path, contents);
          return null;
        },
        log(message) {
          console.log(message);
          return null;
        }
      });

      return config;
    },
  },
});