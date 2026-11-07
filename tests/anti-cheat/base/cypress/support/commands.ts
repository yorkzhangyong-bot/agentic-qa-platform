Cypress.Commands.add('login', (email: string) => {
  cy.session(email, () => {
    cy.request('POST', '/api/test/login', { email });
  });
});
