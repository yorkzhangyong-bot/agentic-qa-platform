import { Client } from 'pg';

/** Inserts orders straight into the test database at TEST_DATABASE_URL. */
export async function seedOrders(orders: { id: number; total: number }[]): Promise<void> {
  const client = new Client({ connectionString: process.env.TEST_DATABASE_URL, connectionTimeoutMillis: 10_000 });
  await client.connect();
  try {
    for (const order of orders) {
      await client.query('INSERT INTO orders (id, total) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING', [
        order.id,
        order.total,
      ]);
    }
  } finally {
    await client.end();
  }
}
