/**
 * Default configuration for the KS8500 Authentication Service
 * These values can be overridden by Cypress environment variables or directly in code
 */

const defaultConfig = {
    // Keycloak settings (these will be overridden by Cypress environment variables if present)
    keycloakUrl: 'https://keycloak.pw.keysight.com',
    clientId: 'clt-test-automation-ui',
    realm: 'csspp2025',
    
    // User token settings
    userToken: false,
    
    // Token storage settings
    tokenStorageKey: 'keycloak_token',
    
    // Default expiration for user tokens (in minutes)
    userTokenExpiration: 30,
  };
  
  export default defaultConfig;