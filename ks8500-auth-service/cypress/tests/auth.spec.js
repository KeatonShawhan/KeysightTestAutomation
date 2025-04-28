// cypress/tests/auth.spec.js
describe('KS8500 Authentication', () => {
  it('logs in and saves session token', () => {
    // Get authentication token
    cy.getKeycloakToken();
    
    // Log in to the application
    cy.doTheLogin();
    
    // Verify authentication was successful
    cy.get('@token').should('exist');
    
    // Save the token to a file for use by the bash script
    cy.get('@token').then(token => {
      const metricsDir = './metrics';
      const timestamp = Cypress.env('RUN_TIMESTAMP') || 
                        new Date().toISOString().replace(/[:.]/g, '');
      const sessionFolder = `${metricsDir}/${timestamp}`;
      
      cy.task('writeFile', {
        path: `${sessionFolder}/auth-token.txt`,
        contents: token
      });
      
      cy.log(`Saved auth token to: ${sessionFolder}/auth-token.txt`);
    });
  });
});