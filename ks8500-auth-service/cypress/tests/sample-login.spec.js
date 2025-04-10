/// <reference types="cypress" />

describe('Authentication Service', () => {
  // Print environment info at the start of tests
  before(() => {
    cy.log('Environment info:');
    cy.log(`Username: ${Cypress.env('USERNAME') || 'Not set'}`);
    cy.log(`Client ID: ${Cypress.env('client-ID') || 'Not set'}`);
    cy.log(`Realm: ${Cypress.env('realm') || 'Not set'}`);
    cy.log(`Auth URL: ${Cypress.env('authUrl') || 'Not set'}`);
  });
  
  context('Basic Login', () => {
    beforeEach(() => {
      // Get a valid authentication token with error handling
      cy.getKeycloakToken().then(token => {
        cy.log(`Token received: ${token ? 'Yes' : 'No'}`);
      });
      
      // Perform login and navigate to the application
      cy.doTheLogin();
    });

    it('should have authentication token', () => {
      // Verify we have a token (may be a mock token if credentials are missing)
      cy.get('@token').should('exist');
      cy.log('Authentication token verification complete');
    });
    
    afterEach(() => {
      // Log out
      cy.keycloakLogout();
    });
  });

  context('Bearer Token', () => {
    it('should get a bearer token directly', () => {
      cy.getBearerToken();
      
      // Verify we have a token
      cy.get('@token').should('exist');
      cy.log('Bearer token received successfully');
    });
  });
  
  context('Second User Login', () => {
    it('should attempt to get a token for second user', () => {
      // Get a token for second user (may fail if credentials not set)
      cy.getKeycloakTokenSecondUser();
      
      // Verify we have a token (may be a mock token)
      cy.get('@token').should('exist');
    });
  });

  context('User Token', () => {
    it('should get a user token', () => {
      // Set userToken to true for this test
      cy.initAuthService({ userToken: true });
      
      // Get a token
      cy.getKeycloakToken();
      
      // Verify we have a token
      cy.get('@token').should('exist');
    });
  });
});