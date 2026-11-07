describe('Login', () => {
  it('logs in', () => {
    cy.visit('/login');
    cy.get('[data-cy="email"]').type('user@example.com');
    cy.get('[data-cy="submit"]').click();
    cy.get('[data-cy="welcome"]').should('have.text', 'Welcome back');
  });
});
