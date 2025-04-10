// Import the auth service
import '../../index';

// Import Cypress commands for API testing
import 'cypress-keycloak';

// Mock the postUserToken command for testing
Cypress.Commands.add('postUserToken', (body) => {
  // Mock response for a user token
  return cy.wrap({
    body: {
      Token: 'mock-user-token-' + Cypress._.random(0, 1e6)
    }
  });
});

// Set default environment variables
before(() => {
  // Log loaded environment
  cy.log(`Test environment: ${Cypress.env('environment') || 'default'}`);

  // Default global path
  Cypress.env('globalUserPath', Cypress.env('globalUserPath') || '/users/test-user/');
  
  // Ensure environment variables needed for testing exist
  if (!Cypress.env('globalUsername')) {
    Cypress.env('globalUsername', Cypress.env('USERNAME') || 'test-user@example.com');
    cy.log(`Using username: ${Cypress.env('globalUsername')}`);
  }
  
  if (!Cypress.env('globalPassword')) {
    Cypress.env('globalPassword', Cypress.env('PASSWORD') || 'test-password');
    cy.log('Password has been set');
  }
  
  if (!Cypress.env('globalRealm')) {
    Cypress.env('globalRealm', Cypress.env('realm') || 'csspp2025');
    cy.log(`Using realm: ${Cypress.env('globalRealm')}`);
  }
  
  if (!Cypress.env('globalClientId')) {
    Cypress.env('globalClientId', Cypress.env('client-ID') || 'clt-test-automation-ui');
    cy.log(`Using client ID: ${Cypress.env('globalClientId')}`);
  }
  
  if (!Cypress.env('globalAuthUrl')) {
    Cypress.env('globalAuthUrl', Cypress.env('authUrl') || 'https://keycloak.pw.keysight.com');
    cy.log(`Using auth URL: ${Cypress.env('globalAuthUrl')}`);
  }
  
  if (!Cypress.env('globalRedirectUrl')) {
    Cypress.env('globalRedirectUrl', Cypress.env('redirectUrl') || Cypress.config('baseUrl'));
    cy.log(`Using redirect URL: ${Cypress.env('globalRedirectUrl')}`);
  }
  
  // Generate the global keycloak token URL
  if (!Cypress.env('globalGetKeycloakTokenUrl')) {
    Cypress.env(
      'globalGetKeycloakTokenUrl',
      `${Cypress.env('globalAuthUrl')}/auth/realms/${Cypress.env('globalRealm')}/protocol/openid-connect/token`
    );
  }
  
  // Generate the global keycloak logout URL
  if (!Cypress.env('globalKeycloakLogout')) {
    Cypress.env(
      'globalKeycloakLogout',
      `${Cypress.env('globalAuthUrl')}/auth/realms/${Cypress.env('globalRealm')}/protocol/openid-connect/logout`
    );
  }
});

// Skip uncaught exceptions
Cypress.on('uncaught:exception', (err, runnable) => {
  // returning false here prevents Cypress from failing the test
  return false;
});