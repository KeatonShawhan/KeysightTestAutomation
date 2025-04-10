// This file contains Cypress commands for testing the auth service

// Import the service for testing
import '../../index';

// Add additional test-specific commands here
Cypress.Commands.add('verifyAuthentication', () => {
  // A simple helper command to verify auth state
  cy.get('@token').should('exist');
  
  // Example of checking authentication state with an API call
  // This would be customized to your specific API endpoints
  cy.request({
    url: `${Cypress.config('baseUrl')}/api/v0.7/user-info`,
    headers: {
      'Authorization': `Bearer ${cy.get('@token')}`
    }
  }).then(response => {
    expect(response.status).to.eq(200);
    expect(response.body).to.have.property('authenticated', true);
  });
});

// Example of a command to test different auth scenarios
Cypress.Commands.add('testAuthScenario', (scenario) => {
  switch(scenario) {
    case 'expired':
      // Simulate expired token scenario
      cy.intercept('POST', '**/token', {
        statusCode: 401,
        body: {
          error: 'invalid_token',
          error_description: 'Token expired'
        }
      }).as('expiredToken');
      break;
      
    case 'invalid':
      // Simulate invalid credentials
      cy.intercept('POST', '**/token', {
        statusCode: 401,
        body: {
          error: 'invalid_grant',
          error_description: 'Invalid credentials'
        }
      }).as('invalidCredentials');
      break;
      
    case 'success':
      // Simulate successful authentication
      cy.intercept('POST', '**/token', {
        statusCode: 200,
        body: {
          access_token: 'mock-access-token-' + Cypress._.random(0, 1e6),
          token_type: 'bearer',
          expires_in: 300,
          refresh_token: 'mock-refresh-token',
          scope: 'openid profile email'
        }
      }).as('successfulAuth');
      break;
  }
});