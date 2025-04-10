/**
 * KS8500 Authentication Service for Cypress
 * Main entry point
 */

// Export the AuthService class
export { default as AuthService } from './src/auth-service';

// Export the default configuration
export { default as config } from './src/config';

// Re-export the Cypress commands setup
// Note: These exports are used for documentation, but the commands are registered globally
export * from './src/auth-commands';

// Default export for convenience
export { default } from './src/auth-service';