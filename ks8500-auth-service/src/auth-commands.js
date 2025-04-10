/**
 * Cypress commands for Keysight KS8500 Authentication
 * These commands maintain compatibility with existing tests
 */

import AuthService from './auth-service';

// Create a singleton instance of the auth service
let authService = null;

/**
 * Initialize the auth service with custom configuration
 * @param {Object} config Configuration options
 * @returns {Cypress.Chainable} A Cypress chainable that resolves to the auth service
 */
Cypress.Commands.add('initAuthService', (config = {}) => {
  authService = new AuthService(config);
  return cy.wrap(authService);
});

/**
 * Get the current instance of the auth service
 * @returns {AuthService} The auth service instance
 */
function getAuthService() {
  if (!authService) {
    authService = new AuthService();
  }
  return authService;
}

/**
 * Get a Keycloak token for authentication
 * This maintains compatibility with the original getKeycloakToken command
 * @returns {Cypress.Chainable<string>} A Cypress chainable that resolves to the token
 */
Cypress.Commands.add('getKeycloakToken', () => {
  cy.log("Running getKeycloakToken");
  return getAuthService().getToken();
});

/**
 * Get a Keycloak token for the second user
 * @returns {Cypress.Chainable<string>} A Cypress chainable that resolves to the token
 */
Cypress.Commands.add('getKeycloakTokenSecondUser', () => {
  cy.log("Running getKeycloakTokenSecondUser");
  return getAuthService().getToken(true);
});

/**
 * Get a bearer token directly
 * This maintains compatibility with the original getBearerToken command
 * @returns {Cypress.Chainable<string>} A Cypress chainable that resolves to the token
 */
Cypress.Commands.add('getBearerToken', () => {
  return getAuthService().getBearerToken();
});

/**
 * Get a bearer token for the second user
 * This maintains compatibility with the original getBearerTokenSecondUser command
 * @returns {Cypress.Chainable<string>} A Cypress chainable that resolves to the token
 */
Cypress.Commands.add('getBearerTokenSecondUser', () => {
  return getAuthService().getBearerToken(true);
});

/**
 * Get a user token
 * This maintains compatibility with the original getUserTokenGlobal command
 * @param {number} [expirationMinutes=30] Token expiration in minutes
 * @returns {Cypress.Chainable<string>} A Cypress chainable that resolves to the token
 */
Cypress.Commands.add('getUserTokenGlobal', (expirationMinutes = 30) => {
  return getAuthService().getUserToken(expirationMinutes);
});

/**
 * Perform login to the application
 * This maintains compatibility with the original doTheLogin command
 * @param {string} [baseUrl] Optional base URL override
 * @returns {Cypress.Chainable} A Cypress chainable
 */
Cypress.Commands.add('doTheLogin', (baseUrl) => {
  return getAuthService().doLogin(baseUrl);
});

/**
 * Log out from Keycloak
 * This maintains compatibility with the original keycloakLogout command
 * @returns {Cypress.Chainable} A Cypress chainable
 */
Cypress.Commands.add('keycloakLogout', () => {
  return getAuthService().logout();
});

/**
 * Alias for keycloakLogout for more consistent naming
 * @returns {Cypress.Chainable} A Cypress chainable
 */
Cypress.Commands.add('doTheLogout', () => {
  return getAuthService().logout();
});

// Export the AuthService class
export { AuthService };